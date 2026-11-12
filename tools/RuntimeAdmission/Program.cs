using System.Reflection;
using System.Reflection.Metadata;
using System.Reflection.PortableExecutable;
using System.Runtime.Loader;

// This checks the actual PE files. With --pulsar-lib it also exercises the real
// installed Pulsar LocalPlugin runtime gate without launching the game or changing its profile.
try
{
    if (args.Length != 2 && args.Length != 4)
        throw new ArgumentException("Usage: RuntimeAdmission <legacy.dll> <interim.dll> [--pulsar-lib <Libraries/Interim>]");
    var legacyPath = Path.GetFullPath(args[0]);
    var interimPath = Path.GetFullPath(args[1]);
    var legacyReferences = References(legacyPath);
    var interimReferences = References(interimPath);
    Require(legacyReferences.Contains("mscorlib") && !legacyReferences.Contains("System.Runtime"),
        "Legacy payload must be a CLR/.NET Framework assembly");
    Require(interimReferences.Contains("System.Runtime"),
        "Interim payload must reference System.Runtime: Pulsar rejects the net48 DLL before Init");
    Require(!File.ReadAllBytes(legacyPath).SequenceEqual(File.ReadAllBytes(interimPath)),
        "Legacy and Interim payloads must not be the same binary");
    Console.WriteLine("PASS PE metadata: separate CLR and CoreCLR payloads");

    if (args.Length == 4)
    {
        Require(args[2] == "--pulsar-lib", "Expected --pulsar-lib");
        var library = Path.GetFullPath(args[3]);
        AssemblyLoadContext.Default.Resolving += (context, name) =>
        {
            var candidate = Path.Combine(library, name.Name + ".dll");
            return File.Exists(candidate) ? context.LoadFromAssemblyPath(candidate) : null;
        };
        var shared = AssemblyLoadContext.Default.LoadFromAssemblyPath(Path.Combine(library, "Pulsar.Shared.dll"));
        var localType = shared.GetType("Pulsar.Shared.Data.LocalPlugin", true)!;
        var tools = shared.GetType("Pulsar.Shared.Tools", true)!;
        Require((string?)tools.GetProperty("Runtime")!.GetValue(null) == "CoreCLR", "Must test real CoreCLR loader");
        foreach (var (path, accepted) in new[] { (legacyPath, false), (interimPath, true) })
        {
            var plugin = Activator.CreateInstance(localType, path, Path.GetDirectoryName(path))!;
            var supported = (bool)localType.GetMethod("IsSupportedEnvironment")!.Invoke(plugin, null)!;
            Require(supported == accepted, $"Real Pulsar runtime gate: {Path.GetFileName(path)} accepted={supported}, expected={accepted}");
            object?[] parameters = { null };
            var loaded = (bool)localType.GetMethod("TryLoadAssembly")!.Invoke(plugin, parameters)!;
            Require(loaded == accepted, $"Real Pulsar TryLoadAssembly: {Path.GetFileName(path)} loaded={loaded}, expected={accepted}");
            Require((parameters[0] != null) == accepted, "Rejected payload must not be loaded; accepted payload must return an assembly");
            Console.WriteLine($"PASS real Pulsar LocalPlugin: {Path.GetFileName(path)} supported={supported}, loaded={loaded}");
        }
    }
    return 0;
}
catch (Exception exception)
{
    Console.Error.WriteLine("FAIL runtime admission: " + exception);
    return 1;
}

static HashSet<string> References(string path)
{
    using var stream = File.OpenRead(path);
    using var pe = new PEReader(stream);
    var metadata = pe.GetMetadataReader();
    return metadata.AssemblyReferences.Select(handle => metadata.GetString(metadata.GetAssemblyReference(handle).Name)).ToHashSet(StringComparer.Ordinal);
}
static void Require(bool condition, string message)
{
    if (!condition) throw new InvalidOperationException(message);
}
