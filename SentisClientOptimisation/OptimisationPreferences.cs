using System;
using System.IO;
using System.Xml;
using System.Xml.Serialization;
using VRage.FileSystem;

namespace SentisClientOptimisation
{
    internal static class OptimisationPreferences
    {
        internal static OptimisationSettings Current { get; private set; } = new OptimisationSettings();
        private static string _path;

        internal static void Load()
        {
            var root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "SpaceEngineers");
            try { if (MyFileSystem.IsInitialized && !string.IsNullOrEmpty(MyFileSystem.UserDataPath)) root = MyFileSystem.UserDataPath; }
            catch (Exception) { }
            _path = Path.Combine(root, "Storage", "SentisClientOptimisation_Config.xml");
            Current = LoadFrom(_path);
        }

        internal static OptimisationSettings LoadFrom(string path)
        {
            try
            {
                if (!File.Exists(path)) return new OptimisationSettings();
                using (var reader = XmlReader.Create(path, new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null }))
                {
                    var result = (OptimisationSettings)new XmlSerializer(typeof(OptimisationSettings)).Deserialize(reader);
                    result.Normalize();
                    return result;
                }
            }
            catch (Exception e)
            {
                Plugin.Log("Preferences read failed (original preserved): " + e.Message);
                return new OptimisationSettings();
            }
        }

        internal static bool Replace(OptimisationSettings settings)
        {
            var next = settings.Clone();
            next.Normalize();
            if (!SaveTo(_path, next)) return false;
            Current = next;
            return true;
        }

        internal static bool Save() => SaveTo(_path, Current);

        internal static bool SaveTo(string path, OptimisationSettings settings)
        {
            string temporary = null;
            try
            {
                if (string.IsNullOrEmpty(path)) throw new InvalidOperationException("Preferences path is not initialized.");
                Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path)));
                temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
                var copy = settings.Clone();
                copy.Normalize();
                using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                {
                    new XmlSerializer(typeof(OptimisationSettings)).Serialize(stream, copy);
                    stream.Flush(true);
                }
                if (File.Exists(path)) File.Replace(temporary, path, path + ".bak");
                else File.Move(temporary, path);
                return true;
            }
            catch (Exception e)
            {
                Plugin.Log("Preferences write failed: " + e.Message);
                return false;
            }
            finally
            {
                try { if (temporary != null && File.Exists(temporary)) File.Delete(temporary); }
                catch (Exception) { }
            }
        }
    }
}
