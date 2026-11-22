using Juggle.Core;
using Juggle.Core.Jobs;

namespace Juggle.Core.Tests.Jobs;

public class WakeJobTests
{
    [Fact]
    public void Wakes_the_screen_over_ssh()
    {
        var host = new FakeHost();
        var pi = new ScriptedPi();

        var woke = new WakeJob(host, connect: _ => pi).Run("Juggle-Test");

        Assert.True(woke);
        Assert.Equal([WakeJob.Command], pi.Commands);
        Assert.Contains("woke", host.Said[0], StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Says_so_when_the_pi_cannot_be_reached()
    {
        var host = new FakeHost();
        var pi = new ThrowingPi(new PiCommandException(255, "ssh: connect to host x.local: timed out"));

        var woke = new WakeJob(host, connect: _ => pi).Run("juggle-test");

        Assert.False(woke);
        Assert.Contains("Couldn't connect", host.Problems[0]);
    }

    [Fact]
    public void Refuses_a_name_that_is_not_a_hostname()
    {
        var host = new FakeHost();

        Assert.False(new WakeJob(host, connect: _ => new ScriptedPi()).Run("bad name"));
        Assert.Single(host.Problems);
    }

    sealed class ThrowingPi(PiCommandException error) : IPi
    {
        public string Host => "x.local";
        public string Run(string command, Action<string>? onMessage = null, int connectTimeoutSeconds = 15) => throw error;
        public string Run(string command, string inputFile, IProgress<long> progress, Action<string>? onMessage = null) => throw error;
    }
}
