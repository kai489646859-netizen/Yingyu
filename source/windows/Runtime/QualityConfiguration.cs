using System.Globalization;
using System.Text;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage.Pickers;

namespace Yingyu.Update;

internal static class QualityConfiguration
{
    static readonly string[] Scalers=["bilinear","bicubic","spline16","spline36","spline64","mitchell","lanczos",
        "ewa_lanczos","ewa_lanczossharp","ewa_lanczos4sharpest","nearest"];
    const int MaxConfigLength=16384;
    const long MaxPackageBytes=90L*1024*1024;
    sealed record Shader(string Name,byte[] Bytes);
    sealed record Package(int Schema,int Preset,bool ShadersEnabled,bool Automatic,string Mpv,Shader[] Shaders);

    internal static string[] Parse(string text)
    {
        if(text.Length>MaxConfigLength)throw new InvalidDataException("画质配置超出 16 KiB。");
        var options=new Dictionary<string,string>(StringComparer.Ordinal);
        int number=0;
        foreach(string raw in text.Split('\n'))
        {
            number++;
            string line=raw.Split('#',2)[0].Trim();
            if(line.Length==0)continue;
            var parts=line.Split('=',2,StringSplitOptions.TrimEntries);
            if(parts.Length!=2||!Valid(parts[0],parts[1]))
                throw new InvalidDataException($"第 {number} 行的选项或参数无效。");
            options[parts[0]]=parts[1];
        }
        return options.Select(option=>option.Key+"="+option.Value).ToArray();
    }

    static bool Valid(string key,string value)
    {
        static bool Within(string text,int max)=>int.TryParse(text,NumberStyles.None,CultureInfo.InvariantCulture,out int n)&&n<=max;
        return key switch
        {
            "scale" or "cscale" or "dscale"=>Scalers.Contains(value,StringComparer.Ordinal),
            "deband" or "correct-downscaling" or "sigmoid-upscaling"=>value is "yes" or "no",
            "deband-iterations"=>Within(value,16),
            "deband-range"=>Within(value,64)&&int.Parse(value,CultureInfo.InvariantCulture)>0,
            "deband-threshold" or "deband-grain"=>Within(value,4096),
            _=>false
        };
    }

    internal static void Overlay(List<string> options,IEnumerable<string> additions)
    {
        foreach(string value in additions)
        {
            string key=value[..(value.IndexOf('=')+1)];
            options.RemoveAll(existing=>existing.StartsWith(key,StringComparison.Ordinal));
            options.Add(value);
        }
    }

    internal static UIElement Create(Func<DesktopThemeOptions> read,Func<DesktopThemeOptions,bool> save)
    {
        var editor=new TextBox{AcceptsReturn=true,TextWrapping=TextWrapping.NoWrap,FontFamily=new("Consolas"),
            MinHeight=140,MaxHeight=240,MaxLength=MaxConfigLength,Text=read().QualityMpvOptions};
        var state=new TextBlock{TextWrapping=TextWrapping.Wrap,FontSize=13};
        var automatic=new CheckBox{Content="检测到持续渲染掉帧时自动降到低性能档",IsChecked=read().QualityAutoReduce};
        var pane=new StackPanel{Spacing=8};
        pane.Children.Add(new TextBlock{Text="Ctrl + F8 循环当前影片的 SDR 画质档位。",TextWrapping=TextWrapping.Wrap});
        pane.Children.Add(editor);pane.Children.Add(automatic);
        void Update(DesktopThemeOptions options)
        {
            Parse(options.QualityMpvOptions);
            if(!save(options))throw new IOException("无法保存画质配置。");
            editor.Text=options.QualityMpvOptions;automatic.IsChecked=options.QualityAutoReduce;
            state.Text="已保存，下次开片或切集生效。";
        }
        async Task Transfer(bool export)
        {
            if(pane.XamlRoot is not {} root)return;
            var hwnd=Microsoft.UI.Win32Interop.GetWindowFromWindowId(root.ContentIslandEnvironment.AppWindowId);
            if(export)
            {
                var picker=new FileSavePicker{SuggestedFileName="Yingyu-画质配置"};
                picker.FileTypeChoices.Add("映屿画质配置",[".yingyu-quality"]);
                WinRT.Interop.InitializeWithWindow.Initialize(picker,hwnd);
                if(await picker.PickSaveFileAsync() is not {} file)return;
                var options=read();
                var data=await Task.Run(()=>JsonSerializer.SerializeToUtf8Bytes(new Package(1,options.VideoQualityPreset,
                    options.CustomShadersEnabled,options.QualityAutoReduce,options.QualityMpvOptions,
                    ShaderSettings.Available(options.ShaderFiles).Select(p=>new Shader(ShaderSettings.DisplayName(p),File.ReadAllBytes(p))).ToArray())));
                await Windows.Storage.FileIO.WriteBytesAsync(file,data);state.Text="画质配置已导出。";
            }
            else
            {
                var picker=new FileOpenPicker();picker.FileTypeFilter.Add(".yingyu-quality");
                WinRT.Interop.InitializeWithWindow.Initialize(picker,hwnd);
                if(await picker.PickSingleFileAsync() is not {} file)return;
                var package=await Task.Run(()=>Import(file.Path));
                Update(read() with{VideoQualityPreset=package.Preset,CustomShadersEnabled=package.Enabled,
                    QualityAutoReduce=package.Automatic,QualityMpvOptions=package.Mpv,ShaderFiles=package.Files});
            }
        }
        void Button(string title,Func<Task> action)
        {
            var button=new Button{Content=title};pane.Children.Add(button);
            button.Click+=async(_,_) =>
            {
                button.IsEnabled=false;
                try{await action();}
                catch(Exception error){state.Text=error is InvalidDataException?error.Message:"画质配置操作失败。";}
                finally{button.IsEnabled=true;}
            };
        }
        Button("校验并保存",()=>{Update(read() with{QualityMpvOptions=editor.Text,QualityAutoReduce=automatic.IsChecked==true});return Task.CompletedTask;});
        Button("导入画质配置…",()=>Transfer(false));
        Button("导出画质配置…",()=>Transfer(true));
        Button("恢复默认画质",()=>{Update(read() with{VideoQualityPreset=0,CustomShadersEnabled=false,
            QualityAutoReduce=false,QualityMpvOptions="",ShaderFiles=[]});return Task.CompletedTask;});
        pane.Children.Add(state);
        return new Expander{Header="MPV 画质配置（SDR）",Content=pane};
    }

    static (int Preset,bool Enabled,bool Automatic,string Mpv,string[] Files) Import(string path)
    {
        using var input=File.OpenRead(path);
        if(input.Length is <=0 or >MaxPackageBytes)throw new InvalidDataException("配置文件为空或过大。");
        var data=JsonSerializer.Deserialize<Package>(input);
        if(data is not {Schema:1,Shaders.Length:<=VideoQuality.MaxShaders,Mpv:{}})
            throw new InvalidDataException("画质配置格式不受支持。");
        Parse(data.Mpv);
        if(data.Shaders.Any(s=>s is not {Name.Length:>0 and <=140,Bytes.Length:>0 and <=VideoQuality.MaxShaderBytes}))
            throw new InvalidDataException("画质配置包含无效着色器。");
        foreach(var shader in data.Shaders)ShaderSettings.ValidateShader(shader.Bytes);
        var files=data.Shaders.Select(s=>ShaderSettings.StoreShader(s.Name,s.Bytes)).ToArray();
        return (data.Preset,data.ShadersEnabled,data.Automatic,data.Mpv,files);
    }

    internal static string Sanitize(string? text)
    {
        try{Parse(text??"");return text??"";}
        catch(InvalidDataException){return "";}
    }
}
