/// Stolen from: http://d.puremagic.com/issues/show_bug.cgi?id=4150
import phobosx.signal;
import std.stdio;
import core.thread;
import core.memory;

class Observer
{
    bool DEEAAAD;

    void watch(int i) {
        //this assertion fails sometimes!
        assert(!DEEAAAD, "dead slot called");
    }

    ~this() {
        DEEAAAD = true;
    }
}

class SomeSignal
{
    // Mix in all the code we need to make Foo into a signal
    mixin(signal!int("sig"));
}

void main()
{
    //start a thread which only calls the GC
    void annoy() {
        while (true) {
            GC.collect();
        }
    }
    auto t = new Thread(&annoy);
    t.isDaemon = true;
    t.start();

    //create observers, add them to the signal, and leave the rest to the GC
    auto a = new SomeSignal;
    while (true) {
        for (int n = 0; n < 20; n++) {
            auto o = new Observer();
            a.sig.connect!"watch"(o);
        }
        a._sig.emit(4);
    }
}
