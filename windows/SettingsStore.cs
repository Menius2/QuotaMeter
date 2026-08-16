using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace QuotaMeterWindows;

internal static class SettingsStore
{
    private static readonly string AppDirectory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "QuotaMeter"
    );

    private static readonly string SettingsPath = Path.Combine(AppDirectory, "settings.json");

    public static AppSettings Load()
    {
        var settings = new AppSettings();
        var candidates = new[]
        {
            SettingsPath,
            Path.Combine(AppContext.BaseDirectory, "config.json")
        };

        foreach (var path in candidates)
        {
            if (!File.Exists(path))
            {
                continue;
            }

            try
            {
                using var document = JsonDocument.Parse(File.ReadAllText(path));
                var root = document.RootElement;
                settings.BaseUrl = ReadString(root, "base_url", "BaseUrl") ?? settings.BaseUrl;
                settings.ProviderPreset = ReadString(root, "provider_preset", "ProviderPreset") ?? settings.ProviderPreset;
                settings.UsagePath = ReadString(root, "usage_path", "UsagePath") ?? settings.UsagePath;
                settings.RefreshIntervalSeconds = Math.Max(
                    10,
                    ReadInt(root, "refresh_interval_seconds", "RefreshIntervalSeconds") ?? settings.RefreshIntervalSeconds
                );

                var protectedKey = ReadString(root, "api_key_protected", "ApiKeyProtected");
                var plainKey = ReadString(root, "api_key", "ApiKey");
                settings.ApiKey = !string.IsNullOrWhiteSpace(protectedKey)
                    ? WindowsSecretStore.Unprotect(protectedKey)
                    : plainKey ?? settings.ApiKey;
                return settings;
            }
            catch
            {
                // Ignore malformed local files and continue with defaults.
            }
        }

        return settings;
    }

    public static void Save(AppSettings settings)
    {
        Directory.CreateDirectory(AppDirectory);
        var persisted = new PersistedSettings
        {
            BaseUrl = settings.BaseUrl.Trim(),
            ProviderPreset = settings.ProviderPreset,
            UsagePath = settings.UsagePath,
            RefreshIntervalSeconds = Math.Max(10, settings.RefreshIntervalSeconds),
            ApiKeyProtected = string.IsNullOrWhiteSpace(settings.ApiKey)
                ? ""
                : WindowsSecretStore.Protect(settings.ApiKey.Trim())
        };

        var json = JsonSerializer.Serialize(
            persisted,
            new JsonSerializerOptions { WriteIndented = true }
        );
        File.WriteAllText(SettingsPath, json, Encoding.UTF8);
    }

    private static string? ReadString(JsonElement root, params string[] names)
    {
        foreach (var name in names)
        {
            if (root.TryGetProperty(name, out var property) && property.ValueKind == JsonValueKind.String)
            {
                return property.GetString();
            }
        }

        return null;
    }

    private static int? ReadInt(JsonElement root, params string[] names)
    {
        foreach (var name in names)
        {
            if (!root.TryGetProperty(name, out var property))
            {
                continue;
            }

            if (property.ValueKind == JsonValueKind.Number && property.TryGetInt32(out var number))
            {
                return number;
            }

            if (property.ValueKind == JsonValueKind.String &&
                int.TryParse(property.GetString(), out var parsed))
            {
                return parsed;
            }
        }

        return null;
    }

    private sealed class PersistedSettings
    {
        [JsonPropertyName("base_url")]
        public string BaseUrl { get; set; } = "";

        [JsonPropertyName("provider_preset")]
        public string ProviderPreset { get; set; } = "auto";

        [JsonPropertyName("usage_path")]
        public string UsagePath { get; set; } = "/v1/usage";

        [JsonPropertyName("refresh_interval_seconds")]
        public int RefreshIntervalSeconds { get; set; } = 30;

        [JsonPropertyName("api_key_protected")]
        public string ApiKeyProtected { get; set; } = "";
    }
}

internal static class WindowsSecretStore
{
    [StructLayout(LayoutKind.Sequential)]
    private struct DataBlob
    {
        public int Size;
        public IntPtr Data;
    }

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CryptProtectData(
        ref DataBlob dataIn,
        string? description,
        IntPtr entropy,
        string? reserved,
        IntPtr prompt,
        int flags,
        out DataBlob dataOut
    );

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CryptUnprotectData(
        ref DataBlob dataIn,
        IntPtr description,
        IntPtr entropy,
        string? reserved,
        IntPtr prompt,
        int flags,
        out DataBlob dataOut
    );

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);

    public static string Protect(string value)
    {
        var input = Encoding.UTF8.GetBytes(value);
        var inputPointer = Marshal.AllocHGlobal(input.Length);

        try
        {
            Marshal.Copy(input, 0, inputPointer, input.Length);
            var inputBlob = new DataBlob { Size = input.Length, Data = inputPointer };
            if (!CryptProtectData(ref inputBlob, "QuotaMeter API Key", IntPtr.Zero, null, IntPtr.Zero, 0, out var outputBlob))
            {
                throw new InvalidOperationException("Windows could not protect the API key.");
            }

            try
            {
                var protectedBytes = new byte[outputBlob.Size];
                Marshal.Copy(outputBlob.Data, protectedBytes, 0, outputBlob.Size);
                return Convert.ToBase64String(protectedBytes);
            }
            finally
            {
                LocalFree(outputBlob.Data);
            }
        }
        finally
        {
            Marshal.FreeHGlobal(inputPointer);
        }
    }

    public static string Unprotect(string protectedValue)
    {
        if (string.IsNullOrWhiteSpace(protectedValue))
        {
            return "";
        }

        byte[] protectedBytes;
        try
        {
            protectedBytes = Convert.FromBase64String(protectedValue);
        }
        catch
        {
            return "";
        }

        var inputPointer = Marshal.AllocHGlobal(protectedBytes.Length);
        try
        {
            Marshal.Copy(protectedBytes, 0, inputPointer, protectedBytes.Length);
            var inputBlob = new DataBlob { Size = protectedBytes.Length, Data = inputPointer };
            if (!CryptUnprotectData(ref inputBlob, IntPtr.Zero, IntPtr.Zero, null, IntPtr.Zero, 0, out var outputBlob))
            {
                return "";
            }

            try
            {
                var plainBytes = new byte[outputBlob.Size];
                Marshal.Copy(outputBlob.Data, plainBytes, 0, outputBlob.Size);
                return Encoding.UTF8.GetString(plainBytes);
            }
            finally
            {
                LocalFree(outputBlob.Data);
            }
        }
        finally
        {
            Marshal.FreeHGlobal(inputPointer);
        }
    }
}
