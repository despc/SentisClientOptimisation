# IShellLinkW keeps paths Unicode; WScript.Shell's TargetPath uses the system ANSI code page.
if (-not ('Sentis.Installer.UnicodeShortcut' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;

namespace Sentis.Installer
{
    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    internal class ShellLink { }

    [ComImport, Guid("000214F9-0000-0000-C000-000000000046"),
        InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IShellLinkW
    {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path,
            int count, IntPtr findData, uint flags);
        void GetIDList(out IntPtr itemList);
        void SetIDList(IntPtr itemList);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder text, int count);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string text);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int count);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string path);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder text, int count);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string text);
        void GetHotkey(out short hotkey);
        void SetHotkey(short hotkey);
        void GetShowCmd(out int command);
        void SetShowCmd(int command);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path,
            int count, out int index);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string path, int index);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string path, uint reserved);
        void Resolve(IntPtr window, uint flags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string path);
    }

    public sealed class ShortcutInfo
    {
        public string TargetPath { get; internal set; }
        public string WorkingDirectory { get; internal set; }
        public string IconLocation { get; internal set; }
        public string Description { get; internal set; }
        public int WindowStyle { get; internal set; }
    }

    public static class UnicodeShortcut
    {
        public static void Create(string file, string target, string directory,
            string icon, string description)
        {
            object instance = new ShellLink();
            try
            {
                var link = (IShellLinkW)instance;
                link.SetPath(target);
                link.SetWorkingDirectory(directory);
                link.SetIconLocation(icon, 0);
                link.SetShowCmd(7);
                link.SetDescription(description);
                ((IPersistFile)instance).Save(file, true);
            }
            finally { Marshal.FinalReleaseComObject(instance); }
        }

        public static ShortcutInfo Read(string file)
        {
            object instance = new ShellLink();
            try
            {
                ((IPersistFile)instance).Load(file, 0);
                var link = (IShellLinkW)instance;
                var target = new StringBuilder(32768);
                var directory = new StringBuilder(32768);
                var icon = new StringBuilder(32768);
                var description = new StringBuilder(1024);
                int index, show;
                link.GetPath(target, target.Capacity, IntPtr.Zero, 4);
                link.GetWorkingDirectory(directory, directory.Capacity);
                link.GetIconLocation(icon, icon.Capacity, out index);
                link.GetDescription(description, description.Capacity);
                link.GetShowCmd(out show);
                return new ShortcutInfo {
                    TargetPath = target.ToString(), WorkingDirectory = directory.ToString(),
                    IconLocation = icon.ToString() + "," + index,
                    Description = description.ToString(), WindowStyle = show
                };
            }
            finally { Marshal.FinalReleaseComObject(instance); }
        }
    }
}
'@
}
