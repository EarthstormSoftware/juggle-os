namespace Juggle.Core.Jobs;

/// <summary>
/// Wakes a Pi's sleeping screen over SSH: an HDMI display by the OS's own request, a DSI display by turning its
/// backlight on. The Pi's app still thinks the screen is asleep until it is touched, which does no harm.
/// </summary>
public sealed class WakeJob(IJobHost host, JugglePaths? paths = null, Func<string, IPi>? connect = null)
{
    /// <summary>What runs on the Pi: the HDMI request (only fails if there's no console to wake), then every backlight.</summary>
    public const string Command =
        "sudo /usr/lib/juggle/app-request screen-wake; for b in /sys/class/backlight/*/bl_power; do " +
        "[ -w \"$b\" ] && echo 0 | sudo tee \"$b\" >/dev/null; done; true";

    readonly JugglePaths paths = paths ?? JugglePaths.Default;
    readonly Func<string, IPi> connect = connect ?? (name => new PiShell(PiShell.HostFor(name)));

    /// <summary>Wakes the screen of the Pi called name (asked for if null). Returns whether it could reach the Pi.</summary>
    public bool Run(string? name)
    {
        name = (name ?? host.AskPiName(DeviceStore.Load(paths.DeviceStore).StartingDevice)).ToLowerInvariant();
        if (SettingsRules.CheckHostname(name) is { } problem)
        {
            host.Problem(problem);
            return false;
        }
        var pi = connect(name);
        try
        {
            pi.Run(Command);
        }
        catch (PiCommandException error) when (error.Unreachable)
        {
            host.Problem($"Couldn't connect to {name} ({pi.Host}): {error.Message.TrimEnd('.')}. Make sure it's turned on " +
                "and connected to the network, then try again.");
            return false;
        }
        catch (PiCommandException error)
        {
            host.Problem($"{name} didn't take the request ({error.Message.TrimEnd('.')}). Is its SSH key set up here?");
            return false;
        }
        host.Say($"Woke {name}'s screen.");
        return true;
    }
}
