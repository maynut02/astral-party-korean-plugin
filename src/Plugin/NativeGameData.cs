using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Il2CppInterop.Runtime;

namespace AstralParty.KoreanPatch;

// HybridCLR types have no generated interop wrappers. Cache metadata, not game
// object pointers; missing classes are retried as the runtime assembly loads.
internal sealed class NativeGameData
{
    private readonly Dictionary<string, IntPtr> classes = new(StringComparer.Ordinal);
    private readonly Dictionary<(IntPtr Class, string Name), IntPtr> fields = new();

    // The x64 export writes size_t; the installed Interop binding uses ref uint.
    [DllImport("GameAssembly.dll", EntryPoint = "il2cpp_domain_get_assemblies",
        ExactSpelling = true, CallingConvention = CallingConvention.Cdecl)]
    private static extern unsafe IntPtr* GetDomainAssemblies(IntPtr domain, out nuint count);

    internal unsafe IntPtr FindClass(string assemblyName, string namespaze, string name)
    {
        var key = assemblyName + ":" + namespaze + "." + name;
        if (classes.TryGetValue(key, out var cached)) return cached;
        var assemblies = GetDomainAssemblies(IL2CPP.il2cpp_domain_get(), out var count);
        for (nuint index = 0; index < count; index++)
        {
            var image = IL2CPP.il2cpp_assembly_get_image(assemblies[index]);
            var imageName = Marshal.PtrToStringAnsi(IL2CPP.il2cpp_image_get_name(image));
            if (!string.Equals(imageName, assemblyName, StringComparison.Ordinal)
                && !string.Equals(imageName, assemblyName + ".dll", StringComparison.Ordinal)) continue;
            var klass = IL2CPP.il2cpp_class_from_name(image, namespaze, name);
            if (klass != IntPtr.Zero) classes[key] = klass;
            return klass;
        }
        return IntPtr.Zero;
    }

    internal IntPtr Field(IntPtr klass, string name)
    {
        var key = (klass, name);
        if (fields.TryGetValue(key, out var cached)) return cached;
        for (var current = klass; current != IntPtr.Zero; current = IL2CPP.il2cpp_class_get_parent(current))
        {
            var iterator = IntPtr.Zero;
            IntPtr field;
            while ((field = IL2CPP.il2cpp_class_get_fields(current, ref iterator)) != IntPtr.Zero)
            {
                if (!string.Equals(Marshal.PtrToStringAnsi(IL2CPP.il2cpp_field_get_name(field)), name,
                    StringComparison.Ordinal)) continue;
                fields[key] = field;
                return field;
            }
        }
        return IntPtr.Zero;
    }
}
