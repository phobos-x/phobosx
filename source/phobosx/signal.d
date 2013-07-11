// Written in the D programming language.

/**
 * Signals and Slots are an implementation of the Observer Pattern.
 * Essentially, when a Signal is emitted, a list of connected Observers
 * (called slots) are called.
 *
 *
 * Copyright: Copyright Robert Klotzner 2012 - 2013.
 * License:   <a href="http://www.boost.org/LICENSE_1_0.txt">Boost License 1.0</a>.
 * Authors:   Robert Klotzner
 * Source:    $(PHOBOSSRC std/_signal.d)
 */
/*          Copyright Robert Klotzner 2012 - 2013.
 * Distributed under the Boost Software License, Version 1.0.
 *    (See accompanying file LICENSE_1_0.txt or copy at
 *          http://www.boost.org/LICENSE_1_0.txt)
 *
 * Based on the original implementation written by Walter Bright. (std.signals)
 * I shamelessly stole some ideas of: http://forum.dlang.org/thread/jjote0$1cql$1@digitalmars.com
 * written by Alex Rønne Petersen.
 */
module std.signal;

import core.atomic;
import core.memory;


// Hook into the GC to get informed about object deletions.
private alias void delegate(Object) DisposeEvt;
private extern (C) void  rt_attachDisposeEvent( Object obj, DisposeEvt evt );
private extern (C) void  rt_detachDisposeEvent( Object obj, DisposeEvt evt );
//debug=signal;

/************************
 * Mixin to create a signal within a class object.
 *
 * Different signals can be added to a class by naming the mixins.
 *
 * Example:
---
import std.signal;
import std.stdio;

class Observer
{   // our slot
    void watch(string msg, int i)
    {
        writefln("Observed msg '%s' and value %s", msg, i);
    }
}

class Foo
{
    int value() { return _value; }

    int value(int v)
    {
        if (v != _value)
        {   _value = v;
            // call all the connected slots with the two parameters
            emit("setting new value", v);
        }
        return v;
    }

    // Mix in all the code we need to make Foo into a signal
    mixin Signal!(string, int);

  private :
    int _value;
}

void main()
{
    Foo a = new Foo;
    Observer o = new Observer;

    a.value = 3;                // should not call o.watch()
    a.connect(&o.watch);        // o.watch is the slot
    a.value = 4;                // should call o.watch()
    a.disconnect(&o.watch);     // o.watch is no longer a slot
    a.value = 5;                // so should not call o.watch()
    a.connect(&o.watch);        // connect again
    a.value = 6;                // should call o.watch()
    destroy(o);                 // destroying o should automatically disconnect it
    a.value = 7;                // should not call o.watch()
}
---
 * which should print:
 * <pre>
 * Observed msg 'setting new value' and value 4
 * Observed msg 'setting new value' and value 6
 * </pre>
 *
 */

/**
  * Todo:
  *     - DONE: Handle slots removing/adding slots to the signal. (My current idea will enable adding/removing but will throw an exception if a slot calls emit.)
  *     - DONE: emit called while in emit would easily be possible with fibers, two solutions:
            - simply allow it. Meaning that the second emit is executed before the first one has finished.
            - queue it and execute it, when the first one has finished.
            The second one is more complex to implement, but seems to be the better solution. In fact it is not, because you basically serialize multiple fibers which can pretty much make them useless. In the first case, the slot has to handle the case when being called before an io operation is finished but this also means that it can do load balancing or whatever. With the queue implementation the access would just be serialized and the slot implementation could not do anything about it. So in fact the first implementation is also the expected one, even in the case of fibers.
  *     - DONE: Reduce memory usage by using a single array.
  *     - DONE: Ensure correctness on exceptions (chain them)
  *     - DONE (just did it): Checkout why I should use ==class instead of : Object and do it if it improves things
  * - DONE: Add strongConnect() method.
  * - CANCELED (keep it simple, functionality can be implemented in wrapper delegates if needed): Block signal functionality?
  *     - TODO: Think about const correctness
  * - DONE: Implement postblit and op assign & write unittest for these.
  * - TODO: Document not to rely on order in which the slots are called.
  *     - TODO: Mark it as trusted
  *     - TODO: Write unit tests
  * - DONE: Factor out template agnostic code to non templated code. (Use casts) 
  *     -> Avoids template bloat
  *     -> We can drop linkin()
  * - DONE: Provide a mixin wrapper, so only the containing object can emit a signal, with no additional work needed.
  *     - TODO: Rename it to std.signals2
  *     - TODO: Update documentation
  *     - TODO: Fix coding style to style guidlines of phobos.
  * - TODO: Document design decisions:
        - Why use mixin: So only containing object can emit signals+ copying a signal is not possible.
        - Performance wise: Optimize for very small empty signal, it should be no more than pointer+length. connect/disconnect is optimized to be fast in the case that emit is not currently running. Memory allocation is only done if active.
  *     - Get it into review for phobos :-)
  * - TODO: See if issue 4150 is still present.
  * - TODO:  Check documenation generated by DDOC and improve it.
  * - TODO:  Have it reviewed
  * - TODO: Get it into phobos.
  */
/**
  * Convenience wrapper mixin.
  * It allows you to do someobject.signal.connect() without allowing you to call emit, which only the containing object can.
  * It offers access to the underlying signal object via full (only for the containing object) or restricted for public access.
  */
mixin template Signal(Args...)
{
    private final void emit( Args args )
    {
        full.emit(args);
    }
    final void connect(string method, ClassType)(ClassType obj) if(is(ClassType == class) && __traits(compiles, {void delegate(Args) dg = mixin("&obj."~method);}))
    {
        full.connect!(method, ClassType)(obj);
    }
    final void connect(ClassType)(ClassType obj, void delegate(ClassType obj, Args) dg) if(is(ClassType == class))
    {
        full.connect!ClassType(obj, dg);
    }
    final void strongConnect(void delegate(Args) dg)
    {
        full.strongConnect(dg);
    }
    final void disconnect(string method, ClassType)(ClassType obj) if(is(ClassType == class) && __traits(compiles, {void delegate(Args) dg = mixin("&obj."~method);}))
    {
        full.disconnect!(method, ClassType)(obj);
    }
    final void disconnect(ClassType)(ClassType obj, void delegate(ClassType, T1) dg) if(is(ClassType == class))
    {
        full.disconnect!(ClassType)(obj, dg);
    }
    final void disconnect(ClassType)(ClassType obj) if(is(ClassType == class)) 
    {
        full.disconnect!ClassType(obj);
    }
    final void strongDisconnect(void delegate(Args) dg)
    {
        full.strongDisconnect(dg);
    }
    final ref RestrictedSignal!(Args) restricted() @property
    {
        return full.restricted;
    }
    private FullSignal!(Args) full;
}

struct FullSignal(Args...)
{
    alias restricted this;

    /**
     * Emit the signal.
     *
     * All connected slots which are still alive will be called.  If
     * any of the slots throws an exception, the other slots will
     * still be called. You'll receive a chained exception with all
     * exceptions that happened.
     *
     * The slots are called in the same sequence as they were registered.
     *
     * emit also takes care of actually removing dead connections. For
     * concurrency reasons they are set just to invalid by the GC.
     *
     * If you remove a slot during emit() it won't be called in the
     * current run if it wasn't already.
     */
    void emit( Args args )
    {
        restricted_.impl_.emit(args);
    }

    /**
     * Get access to the rest of the signals functionality.
     */
    ref RestrictedSignal!(Args) restricted() @property
    {
        return restricted_;
    }

    private:
    RestrictedSignal!(Args) restricted_;
}

struct RestrictedSignal(Args...)
{
    /**
      * Direct connection to an object.
      *
      * Use this method if you want to connect directly to an objects method matching the signature of this signal.
      * The connection will have weak reference semantics, meaning if you drop all references to the object the garbage
      * collector will collect it and this connection will be removed.
      * Preconditions: obj must not be null. mixin("&obj."~method) must be valid and compatible.
      * Params:
      *     obj = Some object of a class implementing a method compatible with this signal.
      */
    void connect(string method, ClassType)(ClassType obj) if(is(ClassType == class) && __traits(compiles, {void delegate(Args) dg = mixin("&obj."~method);}))
    in
    {
        assert(obj);
    }
    body
    {
        impl_.addSlot(obj, cast(void delegate())mixin("&obj."~method));
    }
    /**
      * Indirect connection to an object.
      *
      * Use this overload if you want to connect to an object method which does not match the signals signature.
      * You can provide any delegate to do the parameter adaption, but make sure your delegates' context does not contain a reference
      * to the target object, instead use the provided obj parameter, where the object passed to connect will be passed to your delegate.
      * This is to make weak ref semantics possible, if your delegate contains a ref to obj, the object won't be freed as long as
      * the connection remains.
      *
      * Preconditions: obj and dg must not be null (dg's context may). dg's context must not be equal to obj.
      *
      * Params:
      *     obj = The object to connect to. It will be passed to the delegate when the signal is emitted.
      *     dg  = A wrapper delegate which takes care of calling some method of obj. It can do any kind of parameter adjustments necessary.
     */
    void connect(ClassType)(ClassType obj, void delegate(ClassType obj, Args) dg) if(is(ClassType == class))
    in
    {
        assert(obj);
        assert(dg);
        assert(cast(void*)obj !is dg.ptr);
    }
    body
    {
        impl_.addSlot(obj, cast(void delegate()) dg);
    }

    /**
      * Connect with strong ref semantics.
      *
      * Use this overload if you either really really want strong ref semantics for some reason or because you want
      * to connect some non-class method delegate. Whatever the delegates context references, will stay in memory
      * as long as the signals connection is not removed and the signal gets not destroyed itself.
      *
      * Preconditions: dg must not be null. (Its context may.)
      *
      * Params:
      *     dg = The delegate to be connected.
      */
    void strongConnect(void delegate(Args) dg)
    in
    {
        assert(dg);
    }
    body
    {
        impl_.addSlot(null, cast(void delegate()) dg);
    }


    /**
      * Disconnect a direct connection.
      *
      * After issuing this call method of obj won't be triggered any longer when emit is called.
      * Preconditions: Same as for direct connect.
      */
    void disconnect(string method, ClassType)(ClassType obj) if(is(ClassType == class) && __traits(compiles, {void delegate(Args) dg = mixin("&obj."~method);}))
    in
    {
        assert(obj);
    }
    body
    {
        void delegate(Args) dg = mixin("&obj."~method);
        impl_.removeSlot(obj, cast(void delegate()) dg);
    }

    /**
      * Disconnect an indirect connection.
      *
      * For this to work properly, dg has to be exactly the same as the one passed to connect. So if you used a lamda
      * you have to keep a reference to it somewhere, if you want to disconnect the connection later on.
      * If you want to remove all connections to a particular object use the overload which only takes an object paramter.
     */
    void disconnect(ClassType)(ClassType obj, void delegate(ClassType, T1) dg) if(is(ClassType == class))
    in
    {
        assert(obj);
        assert(dg);
    }
    body
    {
        impl_.removeSlot(obj, cast(void delegate())dg);
    }

    /**
      * Disconnect all connections to obj.
      *
      * All connections to obj made with calls to connect are removed. 
     */
    void disconnect(ClassType)(ClassType obj) if(is(ClassType == class)) 
    in
    {
        assert(obj);
    }
    body
    {
        impl_.removeSlot(obj);
    }
    
    /**
      * Disconnect a connection made with strongConnect.
      *
      * Disconnects all connections to dg.
      */
    void strongDisconnect(void delegate(Args) dg)
    in
    {
        assert(dg);
    }
    body
    {
        impl_.removeSlot(null, cast(void delegate()) dg);
    }
    private:
    SignalImpl impl_;
}

private struct SignalImpl
{
    /**
      * Forbit copying.
      *
      * As struct must be relocatable, it is not even possible to
      * provide proper copy support for signals.
      * rt_attachDisposeEvent is used for registering unhook. D's
      * move semantics assume relocatable objects, which results in
      * this(this) being called for one instance and the destructor
      * for another, thus the wrong handlers are deregistered.  Not
      * even destructive copy semantics are really possible, if you
      * want to be safe, because of the explicit move() call.  So even
      * if this(this) immediately drops the array and does not
      * register unhook, D's assumption of relocatable objects is not
      * matched, so move() for example will still simply swap contents
      * of two structs resulting in the wrong unhook delegates being
      * unregistered.
      */
    @disable this(this);
    /// Forbit copying, it does not work. See this(this).
    @disable void opAssign(SignalImpl other);

    void emit(Args...)( Args args )
    {
        int emptyCount=0;
        doEmit(slots_[0 .. $], 0, emptyCount, args);
        slots_=slots_[0 .. $-emptyCount];
        slots_.assumeSafeAppend();
    }

    void addSlot(Object obj, void delegate() dg)
    {
        slots_.length++;
        slots_[$-1] = SlotImpl(obj, dg);
    }
    void removeSlot(Object obj, void delegate() dg)
    {
        auto removal = SlotImpl(obj, dg);
        removeSlot((const ref SlotImpl item) => removal is item);
    }
    void removeSlot(Object obj) 
    {
        removeSlot((const ref SlotImpl item) => item.obj is obj);
    }

    ~this()
    {
        foreach (ref slot; slots_)
        {
            debug (signal) stderr.writeln("Destruction, removing some slot, signal: ", &this);
            slot = SlotImpl.init; // Force destructor to trigger (copy is disabled)
            // This is needed because ATM the GC won't trigger struct destructors to be run when within a GC managed array.
        }
    }
/// Little helper functions:

    /**
     * Find and make invalid any slot for which isRemoved returns true.
     */
    void removeSlot(bool delegate(const ref SlotImpl) isRemoved)
    {
        import std.algorithm : filter;
        foreach (ref slot; slots_)
            if(isRemoved(slot))
                slot = SlotImpl.init;
    }

    /**
     * Helper method to allow all slots being called even in case of an exception. 
     * All exceptions that occur will be chained.
     * Any invalid slots (GC collected or removed) will be dropped.
     */
    void doEmit(Args...)( SlotImpl[] slots, int offset, ref int emptyCount, Args args )
    {
        int i=offset;
        immutable length=slots.length;
        scope (exit) if(i<length-1) doEmit(slots, i+1, emptyCount, args); // Carry on.
        
        for(; i<length; i++)
        {
            if (!slots[i](args)) 
                emptyCount++;
            else if(emptyCount>0)
                slots[i-emptyCount] = SlotImpl(slots[i]);
        }

    }

    SlotImpl[] slots_;
}


// Simple convenience struct for signal implementation.
// Its is inherently unsafe. It is not a template so SignalImpl does not need to be one.
private struct SlotImpl 
{
    @disable this(this);
    
    // Pass null for o if you have a strong ref delegate.
    this(Object o, void delegate() dg) 
    {
        obj_ = WeakRef(o);
        dataPtr_ = dg.ptr;
        funcPtr_ = dg.funcptr;
        if (o && dataPtr_ is cast(void*) o) 
            dataPtr_ = direct_ptr_flag;
        else if (!o)
            hasObject=false;
    }
    /**
     * Implement proper explict move.
     */
    this(ref SlotImpl other) {
        auto o = other.obj;
        obj_ = WeakRef(o);
        dataPtr_ = other.dataPtr_;
        funcPtr_ = other.funcPtr_;
        other = SlotImpl.init; // Destroy original!
    }
    @property Object obj() const
    {
        return obj_.obj;
    }

    /**
     * Whether or not obj_ should contain a valid object. (We have a weak connection)
     */
    bool hasObject() @property const
    {
        return cast(ptrdiff_t) funcPtr_ & 1;
    }
    /**
     * Call the slot.
     *
     * Returns: True if the call was successful (the slot was valid).
     */
    bool opCall(Args...)(Args args)
    {
        auto o = obj;
        void* o_addr = cast(void*)(o);
        
        if (!funcPtr || (hasObject && !o_addr)) 
            return false;
        if (dataPtr_ is direct_ptr_flag || !hasObject)
        {
            void delegate(Args) mdg;
            mdg.funcptr=cast(void function(Args)) funcPtr;
            if(hasObject)
                mdg.ptr = o_addr;
            else
                mdg.ptr = dataPtr_;
            mdg(args);
        }
        else
        {
            void delegate(Object, Args) mdg;
            mdg.ptr = dataPtr_;
            mdg.funcptr = cast(void function(Object, Args)) funcPtr;
            mdg(o, args);
        }
        return true;
    }
private:
    void* funcPtr() @property const
    {
        return cast(void*)( cast(ptrdiff_t)funcPtr_ & ~cast(ptrdiff_t)1);
    }
    void hasObject(bool yes) @property
    {
        funcPtr_ = cast(void*)(cast(ptrdiff_t) funcPtr_ | 1);
    }
    void* funcPtr_;
    void* dataPtr_;
    WeakRef obj_;


    enum direct_ptr_flag = cast(void*)(~0);
    enum strong_ptr_flag = null;
}


// Provides a way of holding a reference to an object, without the GC seeing it.
private struct WeakRef
{
    @disable this(this);
    this(Object o) 
    {
        debug (signal) createdThis=&this;
        if (!o)
            return;
        InvisibleAddress addr = InvisibleAddress(cast(void*)o);
        obj_=addr;
        rt_attachDisposeEvent(o, &unhook);
    }
    Object obj() @property const
    {
        auto o = (cast(InvisibleAddress)atomicLoad(obj_)).address;
        if (GC.addrOf(o))
            return cast(Object)(o);
        return null;
    }
    
    ~this()
    {
        auto o = obj;
        if (o)
        {
            rt_detachDisposeEvent(obj, &unhook);
            unhook(o);
        }
    }
    private:
    debug (signal)
    {
    invariant()
    {
        assert(&this is createdThis, "We changed address! This should really not happen!");
    }
    WeakRef* createdThis;
    }
    void unhook(Object o)
    {
        atomicStore(obj_, InvisibleAddress(null));
    }
    shared(InvisibleAddress) obj_;
}

version(D_LP64) 
{
    struct InvisibleAddress
    {
        this(void* o)
        {
            addr_ = ~cast(ptrdiff_t)(o);
        }
        void* address() @property const
        {
            return cast(void*) ~ addr_;
        }
    private:
        ptrdiff_t addr_ = ~ cast(ptrdiff_t) 0;
    }
}
else 
{
    struct InvisibleAddress
    {
        this(void* o)
        {
            auto tmp = cast(ptrdiff_t) cast(void*) o;
            addr_high = (tmp>>16)&0x0000ffff | 0xffff0000; // Address relies in kernel space
            addr_low = tmp&0x0000ffff | 0xffff0000;
        }
        void* address() @property const
        {
            return cast(void*) (addr_high_<<16 | (addr_low_ & 0x0000ffff));
        }
    private:
        ptrdiff_t addr_high_ = 0;
        ptrdiff_t addr_low_ = 0;
    }
}

unittest
{
    class Observer
    {
        void watch(string msg, int i)
        {
            //writefln("Observed msg '%s' and value %s", msg, i);
            captured_value = i;
            captured_msg   = msg;
        }


        int    captured_value;
        string captured_msg;
    }

    class SimpleObserver 
    {
        void watchOnlyInt(int i) {
            captured_value = i;
        }
        int captured_value;
    }

    class Foo
    {
        @property int value() { return _value; }

        @property int value(int v)
        {
            if (v != _value)
            {   _value = v;
                extendedSig.emit("setting new value", v);
                //simpleSig.emit(v);
            }
            return v;
        }

        mixin Signal!(string, int) extendedSig;
        //Signal!(int) simpleSig;

        private:
        int _value;
    }

    Foo a = new Foo;
    Observer o = new Observer;
    SimpleObserver so = new SimpleObserver;
    // check initial condition
    assert(o.captured_value == 0);
    assert(o.captured_msg == "");

    // set a value while no observation is in place
    a.value = 3;
    assert(o.captured_value == 0);
    assert(o.captured_msg == "");

    // connect the watcher and trigger it
    a.extendedSig.connect!"watch"(o);
    a.value = 4;
    assert(o.captured_value == 4);
    assert(o.captured_msg == "setting new value");

    // disconnect the watcher and make sure it doesn't trigger
    a.extendedSig.disconnect!"watch"(o);
    a.value = 5;
    assert(o.captured_value == 4);
    assert(o.captured_msg == "setting new value");
    //a.extendedSig.connect!Observer(o, (obj, msg, i) { obj.watch("Hahah", i); });
    a.extendedSig.connect!Observer(o, (obj, msg, i) => obj.watch("Hahah", i) );

    a.value = 7;        
    debug (signal) stderr.writeln("After asignment!");
    assert(o.captured_value == 7);
    assert(o.captured_msg == "Hahah");
    a.extendedSig.disconnect(o); // Simply disconnect o, otherwise we would have to store the lamda somewhere if we want to disconnect later on.
    // reconnect the watcher and make sure it triggers
    a.extendedSig.connect!"watch"(o);
    a.value = 6;
    assert(o.captured_value == 6);
    assert(o.captured_msg == "setting new value");

    // destroy the underlying object and make sure it doesn't cause
    // a crash or other problems
    debug (signal) stderr.writefln("Disposing");
    destroy(o);
    debug (signal) stderr.writefln("Disposed");
    a.value = 7;
}

unittest {
    class Observer
    {
        int    i;
        long   l;
        string str;

        void watchInt(string str, int i)
        {
            this.str = str;
            this.i = i;
        }

        void watchLong(string str, long l)
        {
            this.str = str;
            this.l = l;
        }
    }

    class Bar
    {
        @property void value1(int v)  { s1.emit("str1", v); }
        @property void value2(int v)  { s2.emit("str2", v); }
        @property void value3(long v) { s3.emit("str3", v); }

        mixin Signal!(string, int)  s1;
        mixin Signal!(string, int)  s2;
        mixin Signal!(string, long) s3;
    }

    void test(T)(T a) {
        auto o1 = new Observer;
        auto o2 = new Observer;
        auto o3 = new Observer;

        // connect the watcher and trigger it
        a.s1.connect!"watchInt"(o1);
        a.s2.connect!"watchInt"(o2);
        a.s3.connect!"watchLong"(o3);

        assert(!o1.i && !o1.l && !o1.str);
        assert(!o2.i && !o2.l && !o2.str);
        assert(!o3.i && !o3.l && !o3.str);

        a.value1 = 11;
        assert(o1.i == 11 && !o1.l && o1.str == "str1");
        assert(!o2.i && !o2.l && !o2.str);
        assert(!o3.i && !o3.l && !o3.str);
        o1.i = -11; o1.str = "x1";

        a.value2 = 12;
        assert(o1.i == -11 && !o1.l && o1.str == "x1");
        assert(o2.i == 12 && !o2.l && o2.str == "str2");
        assert(!o3.i && !o3.l && !o3.str);
        o2.i = -12; o2.str = "x2";

        a.value3 = 13;
        assert(o1.i == -11 && !o1.l && o1.str == "x1");
        assert(o2.i == -12 && !o1.l && o2.str == "x2");
        assert(!o3.i && o3.l == 13 && o3.str == "str3");
        o3.l = -13; o3.str = "x3";

        // disconnect the watchers and make sure it doesn't trigger
        a.s1.disconnect!"watchInt"(o1);
        a.s2.disconnect!"watchInt"(o2);
        a.s3.disconnect!"watchLong"(o3);

        a.value1 = 21;
        a.value2 = 22;
        a.value3 = 23;
        assert(o1.i == -11 && !o1.l && o1.str == "x1");
        assert(o2.i == -12 && !o1.l && o2.str == "x2");
        assert(!o3.i && o3.l == -13 && o3.str == "x3");

        // reconnect the watcher and make sure it triggers
        a.s1.connect!"watchInt"(o1);
        a.s2.connect!"watchInt"(o2);
        a.s3.connect!"watchLong"(o3);

        a.value1 = 31;
        a.value2 = 32;
        a.value3 = 33;
        assert(o1.i == 31 && !o1.l && o1.str == "str1");
        assert(o2.i == 32 && !o1.l && o2.str == "str2");
        assert(!o3.i && o3.l == 33 && o3.str == "str3");

        // destroy observers
        destroy(o1);
        destroy(o2);
        destroy(o3);
        a.value1 = 41;
        a.value2 = 42;
        a.value3 = 43;
    }

    test(new Bar);

    class BarDerived: Bar
    {
        @property void value4(int v)  { s4.emit("str4", v); }
        @property void value5(int v)  { s5.emit("str5", v); }
        @property void value6(long v) { s6.emit("str6", v); }

        mixin Signal!(string, int)  s4;
        mixin Signal!(string, int)  s5;
        mixin Signal!(string, long) s6;
    }

    auto a = new BarDerived;

    test!Bar(a);
    test!BarDerived(a);

    auto o4 = new Observer;
    auto o5 = new Observer;
    auto o6 = new Observer;

    // connect the watcher and trigger it
    a.s4.connect!"watchInt"(o4);
    a.s5.connect!"watchInt"(o5);
    a.s6.connect!"watchLong"(o6);

    assert(!o4.i && !o4.l && !o4.str);
    assert(!o5.i && !o5.l && !o5.str);
    assert(!o6.i && !o6.l && !o6.str);

    a.value4 = 44;
    assert(o4.i == 44 && !o4.l && o4.str == "str4");
    assert(!o5.i && !o5.l && !o5.str);
    assert(!o6.i && !o6.l && !o6.str);
    o4.i = -44; o4.str = "x4";

    a.value5 = 45;
    assert(o4.i == -44 && !o4.l && o4.str == "x4");
    assert(o5.i == 45 && !o5.l && o5.str == "str5");
    assert(!o6.i && !o6.l && !o6.str);
    o5.i = -45; o5.str = "x5";

    a.value6 = 46;
    assert(o4.i == -44 && !o4.l && o4.str == "x4");
    assert(o5.i == -45 && !o4.l && o5.str == "x5");
    assert(!o6.i && o6.l == 46 && o6.str == "str6");
    o6.l = -46; o6.str = "x6";

    // disconnect the watchers and make sure it doesn't trigger
    a.s4.disconnect!"watchInt"(o4);
    a.s5.disconnect!"watchInt"(o5);
    a.s6.disconnect!"watchLong"(o6);

    a.value4 = 54;
    a.value5 = 55;
    a.value6 = 56;
    assert(o4.i == -44 && !o4.l && o4.str == "x4");
    assert(o5.i == -45 && !o4.l && o5.str == "x5");
    assert(!o6.i && o6.l == -46 && o6.str == "x6");

    // reconnect the watcher and make sure it triggers
    a.s4.connect!"watchInt"(o4);
    a.s5.connect!"watchInt"(o5);
    a.s6.connect!"watchLong"(o6);

    a.value4 = 64;
    a.value5 = 65;
    a.value6 = 66;
    assert(o4.i == 64 && !o4.l && o4.str == "str4");
    assert(o5.i == 65 && !o4.l && o5.str == "str5");
    assert(!o6.i && o6.l == 66 && o6.str == "str6");

    // destroy observers
    destroy(o4);
    destroy(o5);
    destroy(o6);
    a.value4 = 44;
    a.value5 = 45;
    a.value6 = 46;
}

version(none) { // Disabled because of dmd @@@BUG7758@@@
unittest 
{
    import std.stdio;

    struct Property 
    {
        alias value this;
        mixin Signal!(int) signal;
        @property int value() 
        {
            return value_;
        }
        ref Property opAssign(int val) 
        {
            debug (signal) writeln("Assigning int to property with signal: ", &this);
            value_ = val;
            signal.emit(val);
            return this;
        }
        private: 
        int value_;
    }

    void observe(int val)
    {
        debug (signal) writefln("observe: Wow! The value changed: %s", val);
    }

    class Observer 
    {
        void observe(int val)
        {
            debug (signal) writefln("Observer: Wow! The value changed: %s", val);
            debug (signal) writefln("Really! I must know I am an observer (old value was: %s)!", observed);
            observed = val;
            count++;
        }
        int observed;
        int count;
    }
    Property prop;
    void delegate(int) dg = (val) => observe(val);
    prop.signal.strongConnect(dg);
    assert(prop.signal.full.impl_.slots_.length==1);
    Observer o=new Observer;
    prop.signal.connect!"observe"(o);
    assert(prop.signal.full.impl_.slots_.length==2);
    debug (signal) writeln("Triggering on original property with value 8 ...");
    prop=8;
    assert(o.count==1);
    assert(o.observed==prop);
}
}
unittest 
{
    import std.conv;
    FullSignal!() s1;
    void testfunc(int id) 
    {
        throw new Exception(to!string(id));
    }
    s1.strongConnect(() => testfunc(0));
    s1.strongConnect(() => testfunc(1));
    s1.strongConnect(() => testfunc(2));
    try {
        s1.emit();
    }
    catch(Exception e) {
        Throwable t=e;
        int i=0;
        while(t) {
            debug (signal) stderr.writefln("Caught exception (this is fine)");
            assert(to!int(t.msg)==i);
            t=t.next;
            i++;
        }
        assert(i==3);
    }
}
version(none) // Disabled because of dmd @@@BUG5028@@@
unittest
{
    class A
    {
        mixin Signal!(string, int) s1;
    }

    class B : A
    {
        mixin Signal!(string, int) s2;
    }
}
/* vim: set ts=4 sw=4 expandtab : */
