using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Il2CppInterop.Runtime;
using UnityEngine;

namespace AstralParty.KoreanPatch;

// FairyGUI lives in the HybridCLR AstralParty.Runtime assembly. Resolve exact
// parameter types before invoking it; parameter counts alone are not safe.
// This bridge and every object it returns are main-thread only.
internal static unsafe class FairyGui
{
    internal const string Float = "System.Single";
    internal const string Bool = "System.Boolean";
    internal const string Int = "System.Int32";
    internal const string String = "System.String";
    internal const string ColorType = "UnityEngine.Color";
    private static readonly NativeGameData Metadata = new();
    private static readonly Dictionary<(IntPtr Class, string Name, string Signature), IntPtr> Methods = new();

    internal static bool TryClass(string name, out IntPtr klass)
    {
        klass = Metadata.FindClass("AstralParty.Runtime", "FairyGUI", name);
        return klass != IntPtr.Zero;
    }

    internal static IntPtr Class(string name) => TryClass(name, out var klass)
        ? klass : throw new TypeLoadException("Game UI type is unavailable: FairyGUI." + name);

    private static IntPtr Method(IntPtr klass, string name, string signature)
    {
        var key = (klass, name, signature);
        if (Methods.TryGetValue(key, out var cached)) return cached;
        var parameters = signature.Length == 0 ? Array.Empty<string>() : signature.Split(',');
        for (var current = klass; current != IntPtr.Zero; current = IL2CPP.il2cpp_class_get_parent(current))
        {
            var iterator = IntPtr.Zero;
            IntPtr method;
            while ((method = IL2CPP.il2cpp_class_get_methods(current, ref iterator)) != IntPtr.Zero)
            {
                if (IL2CPP.il2cpp_method_get_param_count(method) != parameters.Length
                    || !string.Equals(Marshal.PtrToStringAnsi(IL2CPP.il2cpp_method_get_name(method)), name, StringComparison.Ordinal))
                    continue;
                var matches = true;
                for (var index = 0; matches && index < parameters.Length; index++)
                {
                    var typeName = IL2CPP.il2cpp_type_get_name(IL2CPP.il2cpp_method_get_param(method, (uint)index));
                    try { matches = string.Equals(Marshal.PtrToStringAnsi(typeName), parameters[index], StringComparison.Ordinal); }
                    finally { IL2CPP.il2cpp_free(typeName); }
                }
                if (!matches) continue;
                Methods[key] = method;
                return method;
            }
        }
        throw new MissingMethodException("FairyGUI." + name + "(" + signature + ")");
    }

    private static IntPtr InstanceMethod(IntPtr instance, string name, string signature)
    {
        if (instance == IntPtr.Zero) throw new NullReferenceException("Game UI object is unavailable for " + name);
        return Method(IL2CPP.il2cpp_object_get_class(instance), name, signature);
    }

    private static IntPtr Invoke(IntPtr method, IntPtr instance, void** arguments)
    {
        var exception = IntPtr.Zero;
        var result = IL2CPP.il2cpp_runtime_invoke(method, instance, arguments, ref exception);
        Il2CppException.RaiseExceptionIfNecessary(exception);
        return result;
    }

    internal static IntPtr New(IntPtr klass)
    {
        var instance = IL2CPP.il2cpp_object_new(klass);
        Invoke(Method(klass, ".ctor", string.Empty), instance, null);
        return instance;
    }

    internal static IntPtr NewWithObjects(IntPtr klass, string signature, IntPtr first, IntPtr second)
    {
        var instance = IL2CPP.il2cpp_object_new(klass);
        void** arguments = stackalloc void*[2];
        arguments[0] = (void*)first;
        arguments[1] = (void*)second;
        Invoke(Method(klass, ".ctor", signature), instance, arguments);
        return instance;
    }

    internal static IntPtr Call(IntPtr instance, string name) =>
        Invoke(InstanceMethod(instance, name, string.Empty), instance, null);

    internal static IntPtr CallStatic(IntPtr klass, string name) =>
        Invoke(Method(klass, name, string.Empty), IntPtr.Zero, null);

    internal static IntPtr Call<T>(IntPtr instance, string name, string signature, T value) where T : unmanaged
    {
        void** arguments = stackalloc void*[1];
        arguments[0] = &value;
        return Invoke(InstanceMethod(instance, name, signature), instance, arguments);
    }

    internal static IntPtr Call<T1, T2>(IntPtr instance, string name, string signature, T1 first, T2 second)
        where T1 : unmanaged where T2 : unmanaged
    {
        void** arguments = stackalloc void*[2];
        arguments[0] = &first;
        arguments[1] = &second;
        return Invoke(InstanceMethod(instance, name, signature), instance, arguments);
    }

    internal static IntPtr Call<T1, T2, T3>(IntPtr instance, string name, string signature, T1 first, T2 second, T3 third)
        where T1 : unmanaged where T2 : unmanaged where T3 : unmanaged
    {
        void** arguments = stackalloc void*[3];
        arguments[0] = &first;
        arguments[1] = &second;
        arguments[2] = &third;
        return Invoke(InstanceMethod(instance, name, signature), instance, arguments);
    }

    internal static IntPtr CallObject(IntPtr instance, string name, string signature, IntPtr value)
    {
        void** arguments = stackalloc void*[1];
        arguments[0] = (void*)value;
        return Invoke(InstanceMethod(instance, name, signature), instance, arguments);
    }

    internal static void CallStaticObject(IntPtr klass, string name, string signature, IntPtr value)
    {
        void** arguments = stackalloc void*[1];
        arguments[0] = (void*)value;
        Invoke(Method(klass, name, signature), IntPtr.Zero, arguments);
    }

    internal static void CallStaticObjects(IntPtr klass, string name, string signature, IntPtr first, IntPtr second)
    {
        void** arguments = stackalloc void*[2];
        arguments[0] = (void*)first;
        arguments[1] = (void*)second;
        Invoke(Method(klass, name, signature), IntPtr.Zero, arguments);
    }

    internal static void DrawRoundRect(IntPtr shape, float lineSize, Color lineColor, Color fillColor, float radius)
    {
        void** arguments = stackalloc void*[7];
        arguments[0] = &lineSize;
        arguments[1] = &lineColor;
        arguments[2] = &fillColor;
        arguments[3] = &radius;
        arguments[4] = &radius;
        arguments[5] = &radius;
        arguments[6] = &radius;
        Invoke(InstanceMethod(shape, "DrawRoundRect",
            Float + "," + ColorType + "," + ColorType + "," + Float + "," + Float + "," + Float + "," + Float), shape, arguments);
    }

    internal static T Get<T>(IntPtr instance, string getter) where T : unmanaged
    {
        var boxed = Call(instance, getter);
        if (boxed == IntPtr.Zero) throw new InvalidOperationException("Game UI value is unavailable: " + getter);
        return *(T*)IL2CPP.il2cpp_object_unbox(boxed);
    }

    internal static void Set<T>(IntPtr instance, string setter, string signature, T value) where T : unmanaged =>
        Call(instance, setter, signature, value);

    internal static void SetString(IntPtr instance, string setter, string value) =>
        CallObject(instance, setter, String, IL2CPP.ManagedStringToIl2Cpp(value));

    private static IntPtr Field(IntPtr instance, string name)
    {
        var field = Metadata.Field(IL2CPP.il2cpp_object_get_class(instance), name);
        return field != IntPtr.Zero ? field : throw new MissingFieldException("FairyGUI", name);
    }

    internal static IntPtr StaticField(IntPtr klass, string name)
    {
        var field = Metadata.Field(klass, name);
        return field != IntPtr.Zero ? field : throw new MissingFieldException("FairyGUI", name);
    }

    internal static IntPtr ReadStaticObject(IntPtr field)
    {
        IntPtr value = IntPtr.Zero;
        IL2CPP.il2cpp_field_static_get_value(field, &value);
        return value;
    }

    internal static T ReadField<T>(IntPtr instance, string name) where T : unmanaged
    {
        T value = default;
        IL2CPP.il2cpp_field_get_value(instance, Field(instance, name), &value);
        return value;
    }

    internal static void WriteField<T>(IntPtr instance, string name, T value) where T : unmanaged =>
        IL2CPP.il2cpp_field_set_value(instance, Field(instance, name), &value);

    internal static void WriteStringField(IntPtr instance, string name, string value) =>
        IL2CPP.il2cpp_field_set_value(instance, Field(instance, name), (void*)IL2CPP.ManagedStringToIl2Cpp(value));
}
