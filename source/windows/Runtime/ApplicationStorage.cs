using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Security.AccessControl;

namespace Yingyu.Update;

public static class ApplicationStorage
{
    public static string LegacyRoot
    {
        get
        {
            string parent=Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            string current=Path.Combine(parent,"映屿"), original=Path.Combine(parent,"EmbyDesktop");
            // Only this application's historical Windows identity. Never import
            // YingyuPC, Android builders or other similarly named projects.
            return Directory.Exists(current)||!Directory.Exists(original)?current:original;
        }
    }
    static readonly Lazy<string> Root = new(Initialize);
    public static string DataRoot => Root.Value;
    public static void Prepare() => _ = DataRoot;
    static string Initialize()
    {
        try
        {
            string user=WindowsIdentity.GetCurrent().User?.Value ?? throw new IOException("无法确认当前 Windows 用户。");
            return StorageMigration.Prepare(AppContext.BaseDirectory, LegacyRoot, user, secureDirectory: path => Protect(path,user));
        }
        catch(Exception error) when(error is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            // No C-drive fallback and no empty-account startup on failure.
            MessageBoxW(IntPtr.Zero,"无法准备安装目录下的数据。旧账号、设置和观看记录仍保留，尚未切换到新目录。\n请关闭其他映屿窗口，确认安装目录可写且磁盘空间充足后重试。\n\n错误类型："+error.GetType().Name,"映屿 · 数据迁移未完成",0x10);
            throw;
        }
    }
    static void Protect(string path,string user)
    {
        var acl=new DirectorySecurity();
        acl.SetAccessRuleProtection(true,false);
        foreach(var sid in new[]{new SecurityIdentifier(user),new SecurityIdentifier(WellKnownSidType.LocalSystemSid,null),new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid,null)})
            acl.AddAccessRule(new FileSystemAccessRule(sid,FileSystemRights.FullControl,InheritanceFlags.ContainerInherit|InheritanceFlags.ObjectInherit,PropagationFlags.None,AccessControlType.Allow));
        new DirectoryInfo(path).SetAccessControl(acl);
    }
    [DllImport("user32.dll",CharSet=CharSet.Unicode)]
    static extern int MessageBoxW(IntPtr owner,string text,string caption,uint type);
}
