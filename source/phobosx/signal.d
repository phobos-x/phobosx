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


/**
 * string mixin for creating a signal.
 *
 * It creates a FullSignal instance named "_name", where name is given
 * as first parameter with given protection and an accessor method
 * with the current context protection named "name" returning either a
 * ref RestrictedSignal or ref FullSignal depending on the given
 * protection.
 *
 * Params:
 *   name = How the signal should be named. The ref returning function
 *   will be named like this, the actual struct instance will have an
 *   underscore prefixed.
 *   
 *   protection = Can be any valid protection specifier like
 *   "private", "protected", "package" or in addition "none". Default
 *   is "private". It specifies the protection of the struct instance,
 *   if none is given, private is used and the ref returning function
 *   will return a FullSignal instead of a RestrictedSignal. The
 *   protection of the accessor method is specified by the surrounding
 *   protection scope.
 *
 * Example:
 ---
 import std.stdio;
 class MyObject
 {
     mixin(signal!(string, int)("valueChanged"));

     int value() @property { return _value; }
     int value(int v) @property
     {
        if (v != _value)
        {
            _value = v;
            // call all the connected slots with the two parameters
            _valueChanged.emit("setting new value", v);
        }
        return v;
    }
private:
    int _value;
}

class Observer
{   // our slot
    void watch(string msg, int i)
    {
        writefln("Observed msg '%s' and value %s", msg, i);
    }
}
void main()
{
    auto a = new MyObject;
    Observer o = new Observer;

    a.value = 3;                // should not call o.watch()
    a.valueChanged.connect!"watch"(o);        // o.watch is the slot
    a.value = 4;                // should call o.watch()
    a.valueChanged.disconnect!"watch"(o);     // o.watch is no longer a slot
    a.value = 5;                // so should not call o.watch()
    a.valueChanged.connect!"watch"(o);        // connect again
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
 */
string signal(Args...)(string name, string protection="private")
{
     string argList="(";
     import std.traits : fullyQualifiedName;
     foreach (arg; Args)
     {
         argList~=fullyQualifiedName!(arg)~", ";
     }
     if (argList.length>"(".length)
         argList = argList[0 .. $-2];
     argList ~= ")";

     string output = (protection == "none" ? "private" : protection) ~ " FullSignal!" ~ argList ~ " _" ~ name ~ ";\n";
     string rType= protection == "none" ? "FullSignal!" : "RestrictedSignal!";
     output ~= "ref " ~ rType ~ argList ~ " " ~ name ~ "() { return _" ~ name ~ ";}\n";
     return output;
 }

debug (signal) pragma(msg, signal!int("haha"));

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
        restricted_._impl.emit(args);
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
      * Use this method if you want to connect directly to an objects
      * method matching the signature of this signal.  The connection
      * will have weak reference semantics, meaning if you drop all
      * references to the object the garbage collector will collect it
      * and this connection will be removed.
      *
      * Preconditions: obj must not be null. mixin("&obj."~method)
      * must be valid and compatible.
      * Params:
      *     obj = Some object of a class implementing a method
      *     compatible with this signal.
      */
    void connect(string method, ClassType)(ClassType obj) if (is(ClassType == class) && __traits(compiles, {void delegate(Args) dg = mixin("&obj."~method);}))
    in
    {
        assert(obj);
    }
    body
    {
        _impl.addSlot(obj, cast(void delegate())mixin("&obj."~method));
    }
    /**
      * Indirect connection to an object.
      *
      * Use this overload if you want to connect to an object method
      * which does not match the signals signature.  You can provide
      * any delegate to do the parameter adaption, but make sure your
      * delegates' context does not contain a reference to the target
      * object, instead use the provided obj parameter, where the
      * object passed to connect will be passed to your delegate.
      * This is to make weak ref semantics possible, if your delegate
      * contains a ref to obj, the object won't be freed as long as
      * the connection remains.
      *
      * Preconditions: obj and dg must not be null (dg's context
      * may). dg's context must not be equal to obj.
      *
      * Params:
      *     obj = The object to connect to. It will be passed to the
      *     delegate when the signal is emitted.
      *     
      *     dg = A wrapper delegate which takes care of calling some
      *     method of obj. It can do any kind of parameter adjustments
      *     necessary.
     */
    void connect(ClassType)(ClassType obj, void delegate(ClassType obj, Args) dg) if (is(ClassType == class))
    in
    {
        assert(obj);
        assert(dg);
        assert(cast(void*)obj !is dg.ptr);
    }
    body
    {
        _impl.addSlot(obj, cast(void delegate()) dg);
    }

    /**
      * Connect with strong ref semantics.
      *
      * Use this overload if you either really really want strong ref
      * semantics for some reason or because you want to connect some
      * non-class method delegate. Whatever the delegates context
      * references, will stay in memory as long as the signals
      * connection is not removed and the signal gets not destroyed
      * itself.
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
        _impl.addSlot(null, cast(void delegate()) dg);
    }


    /**
      * Disconnect a direct connection.
      *
      * After issuing this call method of obj won't be triggered any
      * longer when emit is called.
      * Preconditions: Same as for direct connect.
      */
    void disconnect(string method, ClassType)(ClassType obj) if (is(ClassType == class) && __traits(compiles, {void delegate(Args) dg = mixin("&obj."~method);}))
    in
    {
        assert(obj);
    }
    body
    {
        void delegate(Args) dg = mixin("&obj."~method);
        _impl.removeSlot(obj, cast(void delegate()) dg);
    }

    /**
      * Disconnect an indirect connection.
      *
      * For this to work properly, dg has to be exactly the same as
      * the one passed to connect. So if you used a lamda you have to
      * keep a reference to it somewhere if you want to disconnect
      * the connection later on.  If you want to remove all
      * connections to a particular object use the overload which only
      * takes an object paramter.
     */
    void disconnect(ClassType)(ClassType obj, void delegate(ClassType, T1) dg) if (is(ClassType == class))
    in
    {
        assert(obj);
        assert(dg);
    }
    body
    {
        _impl.removeSlot(obj, cast(void delegate())dg);
    }

    /**
      * Disconnect all connections to obj.
      *
      * All connections to obj made with calls to connect are removed. 
     */
    void disconnect(ClassType)(ClassType obj) if (is(ClassType == class)) 
    in
    {
        assert(obj);
    }
    body
    {
        _impl.removeSlot(obj);
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
        _impl.removeSlot(null, cast(void delegate()) dg);
    }
    private:
    SignalImpl _impl;
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
        auto myslots=slots; // Don't remove this! We need to keep an unmodified pointer on the stack!
        if (!isEmitting)
        {
            isEmitting = true;
            scope (exit) isEmitting = false;
        }
        else
            emptyCount = -1;
        doEmit(myslots[0 .. $], 0, emptyCount, args);
        if (emptyCount > 0)
        {
            _slots=myslots[0 .. $-emptyCount]; 
            _slots.assumeSafeAppend();
        }
    }

    void addSlot(Object obj, void delegate() dg)
    {
        bool wasEmitting = isEmitting;
        scope (exit) isEmitting = wasEmitting;
        isEmitting = false;
        if (_slots.capacity <= _slots.length)
        {
            auto buf = new SlotImpl[_slots.length+1];
            foreach (i, ref slot ; _slots)
                buf[i].moveFrom(slot);
            _slots = buf;
        }
        else
            _slots.length++;
        _slots[$-1].construct(obj, dg);
    }
    void removeSlot(Object obj, void delegate() dg)
    {
        SlotImpl removal;
        removal.construct(obj, dg);
        removeSlot((const ref SlotImpl item) => item.wasConstructedFrom(obj, dg));
    }
    void removeSlot(Object obj) 
    {
        removeSlot((const ref SlotImpl item) => item.obj is obj);
    }

    ~this()
    {
        isEmitting = false;
        foreach (ref slot; _slots)
        {
            debug (signal) { import std.stdio; stderr.writefln("Destruction, removing some slot(%s, weakref: %s), signal: ", &slot, &slot._obj, &this); }
            slot.reset(); // This is needed because ATM the GC won't trigger struct
                        // destructors to be run when within a GC managed array.
        }
    }
/// Little helper functions:

    /**
     * Find and make invalid any slot for which isRemoved returns true.
     */
    void removeSlot(bool delegate(const ref SlotImpl) isRemoved)
    {
        bool wasEmitting = isEmitting;
        scope (exit) isEmitting = wasEmitting;
        isEmitting = false;
        foreach (ref slot; _slots)
            if (isRemoved(slot))
                slot.reset();
    }

    /**
     * Helper method to allow all slots being called even in case of an exception. 
     * All exceptions that occur will be chained.
     * Any invalid slots (GC collected or removed) will be dropped.
     */
    static void doEmit(Args...)( SlotImpl[] slots, int offset, ref int emptyCount, Args args )
    {
        int i=offset;
        immutable ptrdiff_t length=slots.length;
        scope (exit) if (i<length-1) doEmit(slots, i+1, emptyCount, args); // Carry on.
        if (emptyCount == -1)
            for (; i<length; i++)
                slots[i](args);
        else
            for (; i<length; i++)
            {
                if (!slots[i](args)) 
                    emptyCount++;
                else if (emptyCount>0)
                {
                    debug (signal) slots[i-emptyCount].reset();
                    slots[i-emptyCount].moveFrom(slots[i]);
                }
            }
    }

    /**
     * We use the lsb of _slots.ptr for marking whether an emit is currently in progress.
     *
     * This is strictly speaking not allowed with GC managed memory
     * (see: http://dlang.org/garbage.html), but if we keep a copy of
     * the pointer on the stack which does not have the lsb set, we
     * should be fine.
     */
    SlotImpl[] slots() @property
    {
        SlotImpl* mslots = _slots.ptr;
        mslots = cast(SlotImpl*) (cast(ptrdiff_t) mslots &  ~ cast(ptrdiff_t) 1);
        return mslots[0 .. _slots.length];
    }
    void isEmitting(bool yes) @property
    {
        SlotsABI* mslots = cast(SlotsABI*) &_slots;
        if (yes)
            mslots.ptr = cast(SlotImpl*)(cast(ptrdiff_t) mslots.ptr | 1);
        else
            mslots.ptr = cast(void*)(cast(ptrdiff_t) mslots.ptr & ~cast(ptrdiff_t) 1);
    }
    bool isEmitting() @property const
    {
        return cast(ptrdiff_t) _slots.ptr & 1;
    }
    SlotImpl[] _slots;
    struct SlotsABI { // Needed for writing _slots.ptr for our hacky mark thingy.
        size_t length;
        size_t ptr;
    }
}


// Simple convenience struct for signal implementation.
// Its is inherently unsafe. It is not a template so SignalImpl does
// not need to be one.
private struct SlotImpl 
{
    @disable this(this);
    @disable void opAssign(SlotImpl other);
    
    /// Pass null for o if you have a strong ref delegate.
    /// dg.funcptr must not point to heap memory.
    void construct(Object o, void delegate() dg)
    in { assert(this is SlotImpl.init); }
    body
    {
        _obj.construct(o);
        _dataPtr = dg.ptr;
        _funcPtr = dg.funcptr;
        assert(GC.addrOf(_funcPtr) is null, "Your function is implemented on the heap? Such dirty tricks are not supported with std.signal!");
        if (o)
        {
            if (_dataPtr is cast(void*) o) 
                _dataPtr = directPtrFlag;
            hasObject = true;
        }
    }

    /**
     * Check whether this slot was constructed from object o and delegate dg.
     */
    bool wasConstructedFrom(Object o, void delegate() dg) const
    {
        if ( o && dg.ptr is cast(void*) o)
            return obj is o && _dataPtr is directPtrFlag && funcPtr is dg.funcptr;
        else
            return obj is o && _dataPtr is dg.ptr && funcPtr is dg.funcptr;
    }
    /**
     * Implement proper explict move.
     */
    void moveFrom(ref SlotImpl other)
    in { assert(this is SlotImpl.init); }
    body
    {
        auto o = other.obj;
        _obj.construct(o);
        _dataPtr = other._dataPtr;
        _funcPtr = other._funcPtr;
        other.reset(); // Destroy original!
        
    }
    @property Object obj() const
    {
        return _obj.obj;
    }

    /**
     * Whether or not _obj should contain a valid object. (We have a weak connection)
     */
    bool hasObject() @property const
    {
        return cast(ptrdiff_t) _funcPtr & 1;
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
        if (_dataPtr is directPtrFlag || !hasObject)
        {
            void delegate(Args) mdg;
            mdg.funcptr=cast(void function(Args)) funcPtr;
            debug (signal) { import std.stdio; writefln("hasObject: %s, o_addr: %s, dataPtr: %s", hasObject, o_addr, _dataPtr);}
            assert((hasObject && _dataPtr is directPtrFlag) || (!hasObject && _dataPtr !is directPtrFlag));
            if (hasObject)
                mdg.ptr = o_addr;
            else
                mdg.ptr = _dataPtr;
            mdg(args);
        }
        else
        {
            void delegate(Object, Args) mdg;
            mdg.ptr = _dataPtr;
            mdg.funcptr = cast(void function(Object, Args)) funcPtr;
            mdg(o, args);
        }
        return true;
    }
    /**
     * Reset this instance to its intial value.
     */   
    void reset() {
        _funcPtr = SlotImpl.init._funcPtr;
        _dataPtr = SlotImpl.init._dataPtr;
        _obj.reset();
    }
private:
    void* funcPtr() @property const
    {
        return cast(void*)( cast(ptrdiff_t)_funcPtr & ~cast(ptrdiff_t)1);
    }
    void hasObject(bool yes) @property
    {
        if (yes)
            _funcPtr = cast(void*)(cast(ptrdiff_t) _funcPtr | 1);
        else
            _funcPtr = cast(void*)(cast(ptrdiff_t) _funcPtr & ~cast(ptrdiff_t)1);
    }
    void* _funcPtr;
    void* _dataPtr;
    WeakRef _obj;


    enum directPtrFlag = cast(void*)(~0);
}


// Provides a way of holding a reference to an object, without the GC seeing it.
private struct WeakRef
{
    @disable this(this);
    @disable void opAssign(WeakRef other);
    void construct(Object o) 
    in { assert(this is WeakRef.init); }
    body
    {
        debug (signal) createdThis=&this;
        debug (signal) { import std.stdio; writefln("WeakRef.construct for %s and object: %s", &this, o); }
        if (!o)
            return;
        _obj = InvisibleAddress(cast(void*)o);
        rt_attachDisposeEvent(o, &unhook);
    }
    Object obj() @property const
    {
        version (none) auto tmp = cast(InvisibleAddress) atomicLoad(_obj); // Does not work
        auto tmp = cast(InvisibleAddress) _obj;
        auto o = tmp.address;
        debug (signal) { import std.stdio; writefln("WeakRef.obj for %s and object: %s", &this, o); }
        if (GC.addrOf(o))
            return cast(Object)(o);
        return null;
    }
    /**
     * Reset this instance to its intial value.
     */   
    void reset() {
        auto o = obj;
        debug (signal) { import std.stdio; writefln("WeakRef.reset for %s and object: %s", &this, o); }
        if (o)
        {
            rt_detachDisposeEvent(obj, &unhook);
            unhook(o);
        }
        debug (signal) createdThis = null;
    }
    
    ~this()
    {
        reset();
    }
    private:
    debug (signal)
    {
    invariant()
    {
        import std.conv : text;
        assert(createdThis is null || &this is createdThis, text("We changed address! This should really not happen! Orig address: ", cast(void*)createdThis, " new address: ", cast(void*)&this));
    }
    WeakRef* createdThis;
    }
    void unhook(Object o)
    {
        version (none) atomicStore(_obj, InvisibleAddress(null));
        _obj = InvisibleAddress(null);
    }
    shared(InvisibleAddress) _obj;
}

version(D_LP64) 
{
    struct InvisibleAddress
    {
        this(void* o)
        {
            _addr = ~cast(ptrdiff_t)(o);
            debug (signal) debug (3) { import std.stdio; writeln("Constructor _addr: ", _addr);}
            debug (signal) debug (3) { import std.stdio; writeln("Constructor ~_addr: ", ~_addr);}
        }
        void* address() @property const
        {
            debug (signal) debug (3) { import std.stdio; writeln("_addr: ", _addr);}
            debug (signal) debug (3) { import std.stdio; writeln("~_addr: ", ~_addr);}
            return cast(void*) ~ _addr;
        }
    private:
        ptrdiff_t _addr = ~ cast(ptrdiff_t) 0;
    }
}
else 
{
    struct InvisibleAddress
    {
        this(void* o)
        {
            auto tmp = cast(ptrdiff_t) cast(void*) o;
            _addrHigh = (tmp>>16)&0x0000ffff | 0xffff0000; // Address relies in kernel space
            _addrLow = tmp&0x0000ffff | 0xffff0000;
        }
        void* address() @property const
        {
            return cast(void*) (_addrHigh<<16 | (_addrLow & 0x0000ffff));
        }
    private:
        ptrdiff_t _addrHigh = 0;
        ptrdiff_t _addrLow = 0;
    }
}
unittest { // Check that above example really works ...
    debug (signal) import std.stdio;
    class MyObject
    {
        mixin(signal!(string, int)("valueChanged"));

        int value() @property { return _value; }
        int value(int v) @property
        {
            if (v != _value)
            {
                _value = v;
                // call all the connected slots with the two parameters
                _valueChanged.emit("setting new value", v);
            }
            return v;
        }
    private:
        int _value;
    }

    class Observer
    {   // our slot
        void watch(string msg, int i)
        {
            debug (signal) writefln("Observed msg '%s' and value %s", msg, i);
        }
    }

    auto a = new MyObject;
    Observer o = new Observer;

    a.value = 3;                // should not call o.watch()
    a.valueChanged.connect!"watch"(o);        // o.watch is the slot
    a.value = 4;                // should call o.watch()
    a.valueChanged.disconnect!"watch"(o);     // o.watch is no longer a slot
    a.value = 5;                // so should not call o.watch()
    a.valueChanged.connect!"watch"(o);        // connect again
    a.value = 6;                // should call o.watch()
    destroy(o);                 // destroying o should automatically disconnect it
    a.value = 7;                // should not call o.watch()

}

unittest
{
    debug (signal) import std.stdio;
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
                _extendedSig.emit("setting new value", v);
                //_simpleSig.emit(v);
            }
            return v;
        }

        mixin(signal!(string, int)("extendedSig"));
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
        @property void value1(int v)  { _s1.emit("str1", v); }
        @property void value2(int v)  { _s2.emit("str2", v); }
        @property void value3(long v) { _s3.emit("str3", v); }

        mixin(signal!(string, int) ("s1"));
        mixin(signal!(string, int) ("s2"));
        mixin(signal!(string, long)("s3"));
    }

    void test(T)(T a)
    {
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
        @property void value4(int v)  { _s4.emit("str4", v); }
        @property void value5(int v)  { _s5.emit("str5", v); }
        @property void value6(long v) { _s6.emit("str6", v); }

        mixin(signal!(string, int) ("s4"));
        mixin(signal!(string, int) ("s5"));
        mixin(signal!(string, long)("s6"));
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

version(none)
{ // Disabled because of dmd @@@BUG7758@@@
unittest 
{
    import std.stdio;

    struct Property 
    {
        alias value this;
        mixin(signal!(int)("signal"));
        @property int value() 
        {
            return value_;
        }
        ref Property opAssign(int val) 
        {
            debug (signal) writeln("Assigning int to property with signal: ", &this);
            value_ = val;
            _signal.emit(val);
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
    assert(prop.signal.full._impl._slots.length==1);
    Observer o=new Observer;
    prop.signal.connect!"observe"(o);
    assert(prop.signal.full._impl._slots.length==2);
    debug (signal) writeln("Triggering on original property with value 8 ...");
    prop=8;
    assert(o.count==1);
    assert(o.observed==prop);
}
}
unittest 
{
    debug (signal) import std.stdio;
    import std.conv;
    FullSignal!() s1;
    void testfunc(int id) 
    {
        throw new Exception(to!string(id));
    }
    s1.strongConnect(() => testfunc(0));
    s1.strongConnect(() => testfunc(1));
    s1.strongConnect(() => testfunc(2));
    try s1.emit();
    catch(Exception e)
    {
        Throwable t=e;
        int i=0;
        while (t)
        {
            debug (signal) stderr.writefln("Caught exception (this is fine)");
            assert(to!int(t.msg)==i);
            t=t.next;
            i++;
        }
        assert(i==3);
    }
}
unittest
{
    class A
    {
        mixin(signal!(string, int)("s1"));
    }

    class B : A
    {
        mixin(signal!(string, int)("s2"));
    }
}
/* vim: set ts=4 sw=4 expandtab : */
