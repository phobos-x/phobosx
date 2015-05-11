phobosx
=======

Experimental modules that are intended for the phobos standard library
of [D](http://dlang.org).

Currently the only content is phobosx.signal, which is meant as a
replacement for std.signals.

The idea is to put modules which are intended for phobos, here
first. It is experimental because the modules in here will break your
code any time. If you need a reliable, stable API and can't afford
fixing your code to changes, don't use this repository!

Once in the standard library, it is really hard to change anything so
it should be really good once it goes there. A module can only be really,
really good if it had some real world testing and some evolution
behind it, which means breaking changes.

So in contrast to phobos which is supposed to be stable as hell, this
repository is meant to be unstable, more unstable than
most other repositories you will find in the dub registry, because the
developers need the freedom to improve the code in any possible way.

Having said this, modules in this repository should not be considered to be of low quality,
just that the API is allowed to change for improvements.

Even if one manages to submit the perfect module from the start your
code will break once it gets accepted into phobos, as it will get
deprecated and then after some time removed.

You have been warned, I will ignore any whining! ;-)
