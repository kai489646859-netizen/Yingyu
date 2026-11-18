using System.Security.Cryptography;
using System.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage.Pickers;

namespace Yingyu.Update;

internal static class ShaderSettings
{
    static string DirectoryPath => Path.Combine(CachePaths.UserDataRoot, "Shaders");
    static readonly (string Label,string[] Files)[] BuiltIn=
    [
        ("Anime4K",["Anime4K_Restore_CNN_M.glsl","Anime4K_Upscale_CNN_x2_M.glsl"]),
        ("FSRCNNX",["FSRCNNX_x2_8_0_4_1.glsl"]),
        ("ArtCNN",["ArtCNN_v0_C4F8.glsl"]),
        ("RAVU",["ravu_lite_ar_r3.glsl"]),
        ("SSimDownscaler",["SSimDownscaler_RT.glsl"]),
        ("SSimSuperRes",["SSimSuperRes_RT.glsl"]),
        ("KrigBilateral",["KrigBilateral.glsl"])
    ];

    internal static string[] Available(IEnumerable<string> files)
    {
        string root = DirectoryPath;
        return VideoQuality.NormalizeShaders(files).Where(path =>
        {
            try
            {
                if (!CacheLayout.IsWithin(root,path) || !CacheLayout.SamePath(root,Path.GetDirectoryName(path)!)) return false;
                CacheLayout.RejectLinks(path);
                return new FileInfo(path) is {Exists:true,Length:>0 and <=VideoQuality.MaxShaderBytes};
            }
            catch(Exception error) when(error is IOException or UnauthorizedAccessException or ArgumentException) { return false; }
        }).ToArray();
    }

    internal static UIElement Create(Func<DesktopThemeOptions> read, Func<DesktopThemeOptions,bool> save, out Action refresh)
    {
        var pane = new StackPanel { Spacing = 8 };
        var active = new ToggleSwitch { Header = "自定义 GLSL Shader", OnContent = "开启", OffContent = "关闭" };
        var list = new ListView { SelectionMode = ListViewSelectionMode.Single, MaxHeight = 184 };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(list, "已导入的 Shader");
        var picker = new Button { Content = "导入 GLSL…" };
        var builtIn=new ComboBox{Header="内置着色器组合",ItemsSource=BuiltIn.Select(x=>x.Label).ToArray(),SelectedIndex=0};
        var addBuiltIn=new Button{Content="使用所选内置着色器"};
        var up = new Button { Content = "上移" };
        var down = new Button { Content = "下移" };
        var remove = new Button { Content = "移出列表" };
        var hint = new TextBlock { Text = "按列表顺序加载。下次开片或切集生效，适用于 GPU-Next 的 SDR 输出。",
            FontSize = 13, TextWrapping = TextWrapping.Wrap };
        var status = new TextBlock { FontSize = 13, TextWrapping = TextWrapping.Wrap };
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        actions.Children.Add(up);actions.Children.Add(down);actions.Children.Add(remove);
        pane.Children.Add(active);pane.Children.Add(hint);pane.Children.Add(builtIn);pane.Children.Add(addBuiltIn);pane.Children.Add(picker);
        pane.Children.Add(list);pane.Children.Add(actions);pane.Children.Add(status);
        bool updating = false, importing = false;
        void Buttons()
        {
            int index = list.SelectedIndex;
            up.IsEnabled = !importing && index > 0;
            down.IsEnabled = !importing && index >= 0 && index + 1 < list.Items.Count;
            remove.IsEnabled = !importing && index >= 0;
            picker.IsEnabled = !importing && list.Items.Count < VideoQuality.MaxShaders;
            addBuiltIn.IsEnabled=!importing;
        }
        void Refresh(int selected)
        {
            updating = true;
            try
            {
                var settings = read();
                active.IsOn = settings.CustomShadersEnabled;
                list.ItemsSource = settings.ShaderFiles.Select(DisplayName).ToArray();
                list.Visibility = settings.ShaderFiles.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
                actions.Visibility = list.Visibility;
                list.SelectedIndex = selected < settings.ShaderFiles.Length ? selected : settings.ShaderFiles.Length - 1;
                Buttons();
            }
            finally { updating = false; }
        }
        void Save(DesktopThemeOptions settings,int selected)
        {
            status.Text = save(settings) ? "" : "画质设置保存失败。";
            Refresh(selected);
        }
        void Move(int delta)
        {
            var settings = read();
            var files = settings.ShaderFiles.ToArray();
            int index = list.SelectedIndex, target = index + delta;
            if (index < 0 || index >= files.Length || target < 0 || target >= files.Length) return;
            (files[index],files[target]) = (files[target],files[index]);
            Save(settings with { ShaderFiles=files },target);
        }
        active.Toggled += (_,_) => { if(!updating) Save(read() with {CustomShadersEnabled=active.IsOn},list.SelectedIndex); };
        list.SelectionChanged += (_,_) => Buttons();
        up.Click += (_,_) => Move(-1);
        down.Click += (_,_) => Move(1);
        remove.Click += (_,_) =>
        {
            var settings=read();
            int index=list.SelectedIndex;
            if(index < 0 || index >= settings.ShaderFiles.Length) return;
            Save(settings with {ShaderFiles=settings.ShaderFiles.Where((_,i)=>i!=index).ToArray()},index);
        };
        picker.Click += async (_,_) =>
        {
            if(importing || pane.XamlRoot is not {} root) return;
            importing=true;Buttons();status.Text="";
            try
            {
                var dialog=new FileOpenPicker();
                dialog.FileTypeFilter.Add(".glsl");
                var window=Microsoft.UI.Win32Interop.GetWindowFromWindowId(root.ContentIslandEnvironment.AppWindowId);
                WinRT.Interop.InitializeWithWindow.Initialize(dialog,window);
                if(await dialog.PickSingleFileAsync() is not {} file || !pane.IsLoaded) return;
                string copied=await Task.Run(()=>Import(file.Path));
                if(!pane.IsLoaded) return;
                var settings=read();
                var files=VideoQuality.NormalizeShaders(settings.ShaderFiles.Append(copied));
                Save(settings with {ShaderFiles=files},Array.FindIndex(files,p=>p.Equals(copied,StringComparison.OrdinalIgnoreCase)));
                if(status.Text.Length==0 && !active.IsOn) status.Text="已导入。开启自定义 GLSL Shader 后生效。";
            }
            catch(Exception error) when(error is IOException or InvalidDataException or UnauthorizedAccessException or ArgumentException or System.Runtime.InteropServices.COMException)
            { status.Text = error is InvalidDataException ? error.Message : "无法导入此 GLSL 文件。"; }
            finally { importing=false;Buttons(); }
        };
        addBuiltIn.Click+=async(_,_) =>
        {
            int selected=builtIn.SelectedIndex;
            if(importing||selected<0||selected>=BuiltIn.Length)return;
            importing=true;Buttons();
            try
            {
                var choice=BuiltIn[selected];
                string root=Path.Combine(AppContext.BaseDirectory,"QualityShaders");
                var files=await Task.Run(()=>choice.Files.Select(name=>Import(Path.Combine(root,name))).ToArray());
                if(!pane.IsLoaded)return;
                var settings=read();
                var replacing=(selected<=3?BuiltIn.Take(4).SelectMany(option=>option.Files):choice.Files).ToHashSet(StringComparer.OrdinalIgnoreCase);
                var current=settings.ShaderFiles.Where(file=>!replacing.Contains(DisplayName(file))).Concat(files)
                    .Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
                if(current.Length>VideoQuality.MaxShaders)throw new InvalidDataException("着色器列表已满，请先移除其他项目。");
                Save(settings with{CustomShadersEnabled=true,ShaderFiles=current},current.Length-1);
            }
            catch(Exception error){status.Text=error is InvalidDataException?error.Message:"内置着色器无法加载。";}
            finally{importing=false;Buttons();}
        };
        Refresh(-1);
        refresh=()=>Refresh(list.SelectedIndex);
        return pane;
    }

    internal static string DisplayName(string path)
    {
        string name=Path.GetFileName(path);
        return name.Length>65 && name[64]=='-' ? name[65..] : name;
    }

    internal static string Import(string source)
    {
        if (!Path.GetExtension(source).Equals(".glsl",StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("请选择 .glsl 文件。");
        using var input=new FileStream(source,FileMode.Open,FileAccess.Read,FileShare.Read);
        if(input.Length is <=0 or >VideoQuality.MaxShaderBytes) throw new InvalidDataException("GLSL 文件为空或超过 8 MiB。");
        byte[] bytes=new byte[checked((int)input.Length)];
        input.ReadExactly(bytes);
        ValidateShader(bytes);
        return StoreShader(source,bytes);
    }

    internal static void ValidateShader(byte[] bytes)
    {
        string text;
        try{text=new UTF8Encoding(false,true).GetString(bytes);}
        catch(DecoderFallbackException){throw new InvalidDataException("GLSL 文件需要 UTF-8 编码。");}
        if(text.Contains('\0') || !text.Contains("//!HOOK",StringComparison.Ordinal))
            throw new InvalidDataException("文件缺少可识别的 MPV Shader HOOK。");
    }

    internal static string StoreShader(string source,byte[] bytes)
    {
        string safeName=new(Path.GetFileNameWithoutExtension(source).Take(72)
            .Select(c=>char.IsLetterOrDigit(c)||c is '-' or '_'?c:'_').ToArray());
        string root=DirectoryPath;
        string path=Path.Combine(root,Convert.ToHexStringLower(SHA256.HashData(bytes))+"-"+safeName+".glsl");
        if(!VideoQuality.IsSupportedPath(path)) throw new InvalidDataException("当前安装目录无法保存 GLSL 路径。");
        CacheLayout.RejectLinks(path);
        Directory.CreateDirectory(root);
        string temporary=Path.Combine(root,Guid.NewGuid().ToString("N")+".tmp");
        try
        {
            using(var output=new FileStream(temporary,FileMode.CreateNew,FileAccess.Write,FileShare.None))
            { output.Write(bytes);output.Flush(true); }
            File.Move(temporary,path,true);
            return path;
        }
        finally { File.Delete(temporary); }
    }
}
