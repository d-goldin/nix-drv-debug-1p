# How to debug derivations

When starting out with developing derivations, it can be rather confusing to
trouble-shoot the nix code and build process.

This short page aims to explain a few tools and approaches that can help
figuring out what's wrong.

This repository contains a few subfolders with a minimal C program and
expressions defining a derivation. To follow along, you should already know the
basic use of `nix-build` to build nix expressions and be at least vaguely
familiar with C, a C compiler and make.

Each of the folders represents a slightly different type of problem that is
referred to in the different sections below. It should be possible for you to
easily toy around and replicate the results on your own.

One small remark about the code examples: Because we use `stdenv` we already
have most basic tooling available (like cc, make, bintools, coreutils) so we
don't need additional build inputs for most examples.

* broken_nix: Simple syntax error in the nix expression
* broken_code: Build failure due to syntax error in the C source
* breakpoint: Demo of the breakpoint to enter build sandbox

## Fundamentals

It's important to internalize a few core concepts regarding nix lang and
derivations to reduce the amount of frustration when trouble-shooting:

* Nix is pure and functional; it's not possible to manipulate state and
  arbitrary side-effects are disallowed (or discouraged, since some unsafe
  functions to exist)
* Nix is lazily evaluated; the order of statements does not matter and
  expressions are only evaluated when they are consumed
* Nix expressions are used to produce derivations - the actual derivations are
  not in nix anymore but are a serialized representation stored in the nix
  store, suffixed with "*.drv*"

Keeping above points in mind will help to understand why some things seems
harder than they need to be.

## nixfmt: formatting and basic syntax errors

While being a formatting tool first and foremost, nixfmt can be utilized to
detect syntax errors in your code. `nix-build` can do so too, but sometimes the
error messages of `nixfmt` are just nicer. Since it's not really evaluating any of the
expressions it's only helpful for finding simpler mistakes in the files it's run
on.

Trivial example:

```
> nixfmt <<EOF
[ "foo",
  "bar"
  "baz"
]

EOF
<stdin>:1:8:
  |
1 | [ "foo",
  |        ^
unexpected ','
expecting expression
```

## nix repl: interactively trying out expressions

[Source dir](./broken_nix)

When you are receiving a mysterious error, it might help to interactively
evaluate parts of the expression in the `nix repl`.

Let's try to execute our faulty expression first. The following is a way to load
up the whole package expression in the way that's often used around nixpkgs:

```
> nix repl '<nixpkgs>'
[...]
nix-repl> pkgs.callPackage ./broken_nix/default.nix {}
error: cannot coerce a set to a string, at /nix/store/c8gsa6n8lb62xsjkidhivx01a1iyz1y4-nixos-19.09.907.f6dac808387/nixos/pkgs/stdenv/generic/make-derivation.nix:191:19
```

_Note: We are loading up nixpkgs per default. We could also_
_use `:l <nixpkgs>` within the repl instead, or to load up any additional files_
_we want to evaluate. `callPackage` is used for convenience, but it would be also_
_possible to use the more manual approach of `import ./03/default.nix { inherit stdenv; }`_
_- those expressions are not absolutely identical though. Why is a bit outside of the scope of this guide._

Here we see that we are having some issue but the error message does not point
us to any location in our code. We see that apparently a string was expected
somewhere but we don't really know yet where nor which set caused the problem.

If we load up `nix repl` with `--show-trace` we will get a slightly less cryptic
error output:

```
> nix repl '<nixpkgs>' --show-trace
[...]
nix-repl> import ./broken_nix/default.nix { inherit pkgs; inherit stdenv; }
error: while evaluating the derivation attribute 'name' at /nix/store/c8gsa6n8lb62xsjkidhivx01a1iyz1y4-nixos-19.09.907.f6dac808387/nixos/pkgs/stdenv/generic/make-derivation.nix:191:11:
cannot coerce a set to a string, at /nix/store/c8gsa6n8lb62xsjkidhivx01a1iyz1y4-nixos-19.09.907.f6dac808387/nixos/pkgs/stdenv/generic/make-derivation.nix:191:19
```

Here we now see that likely something is wrong with the `name` attribute. We don't
set such an attribute directly, but we set something related (note; `pname` is not a typo,
see [NixPkgs Manual - Using Stdenv](https://nixos.org/nixpkgs/manual/#sec-using-stdenv)):

```
[...]
stdenv.mkDerivation {
  pname = "hello";
  version = { a = "0.0.1"; };
[...]
```

Now we can try to reproduce this error in a simplified way in the repl like so:

```
nix-repl> stdenv.mkDerivation { pname = "hello"; version = { a = "0.0.1"; }; }
error: while evaluating the derivation attribute 'name' at /nix/store/c8gsa6n8lb62xsjkidhivx01a1iyz1y4-nixos-19.09.907.f6dac808387/nixos/pkgs/stdenv/generic/make-derivation.nix:191:11:
cannot coerce a set to a string, at /nix/store/c8gsa6n8lb62xsjkidhivx01a1iyz1y4-nixos-19.09.907.f6dac808387/nixos/pkgs/stdenv/generic/make-derivation.nix:191:19
```

which produces the same error as our full expression. At this point we likely
already know that we made a mistake defining our version as an attribute set
instead of a string and can confirm it with a fixed up expression in the repl;

```
nix-repl> stdenv.mkDerivation { pname = "hello"; version = "0.0.1"; }
«derivation /nix/store/2sx8xf7zlyf7k0dyy14s6p2ifmgl5bir-hello-0.0.1.drv»
```

In more complicated cases it still might be useful to look into the files
mentioned in the trace. In this particular case the mistake becomes quite
obvious once we inspect line 191 in
`/nix/store/c8gsa6n8lb62xsjkidhivx01a1iyz1y4-nixos-19.09.907.f6dac808387/nixos/pkgs/stdenv/generic/make-derivation.nix`:

```
191           name = "${attrs.pname}-${attrs.version}";
```

Now we could just toy around with this on the repl like so:

```
# We can simply set variables like so.
nix-repl> attrs = { pname = "hello"; version = { a = "0.0.1"; }; }

# Now we can just try out the line to confirm our suspicion
nix-repl> name = "${attrs.pname}-${attrs.version}"

# Hmm, so this did not cause the error we expected.
# This is because the expression is evaluated lazily, so we should force the evaluation somehow.
# One way to do so this in the repl is to try and print it:

nix-repl> name
error: cannot coerce a set to a string, at (string):1:11
```

In some cases, like nested structures, just evaluating values in the above way
might be insufficient. In that case `:p` can be sued, as shown below:

```
nix-repl> nested = { a = 23; b = { foo = "foo"; "bar" = "bar"; }; }

nix-repl> nested
{ a = 23; b = { ... }; }

nix-repl> :p nested
{ a = 23; b = { bar = "bar"; foo = "foo"; }; }
```

Nix repl also supports tab-completion, which is useful to explore attributes and
functions like in case of `lib.trace*`;

```
nix-repl> lib.trace<TAB>
lib.traceCall           lib.traceIf             lib.traceShowValMarked  lib.traceValSeq         lib.traceXMLVal
lib.traceCall2          lib.traceSeq            lib.traceVal            lib.traceValSeqFn       lib.traceXMLValMarked
lib.traceCall3          lib.traceSeqN           lib.traceValFn          lib.traceValSeqN
lib.traceCallXml        lib.traceShowVal        lib.traceValIfNot       lib.traceValSeqNFn
```

## *Printf Debugging*

An additional way to add some clarity into more complex expressions, especially
with conditions involved, is using `builtin.trace` or one of the other tracing
functions defined in [debug.nix](https://github.com/NixOS/nixpkgs/blob/master/lib/debug.nix)
and made available via `lib.trace*`. Most of those functions expect an argument that
contains the message to be printed and the value to return from the trace
function when it's evaluated.

A trivial example to showcase how this could be used:

```
nix-repl> mkName = name: surname: builtins.trace "name: ${name} surnamme: ${surname}" { inherit name; inherit surname; }

nix-repl> mkName "First" "Last"
trace: name: First surnamme: Last
{ name = "First"; surname = "Last"; }
```

As the above scenario of just wanting to trace and return the value that is
being passed is so common, there is a helper function `traceVal` to achieve
exactly that:

```
nix-repl> mkName = name: surname: lib.traceVal { inherit name; inherit surname; }

nix-repl> mkName "First" "Last"
trace: { name = "First"; surname = "Last"; }
{ name = "First"; surname = "Last"; }
```

The other functions in `debug.nix` are adopted to various cases and the source
should be consulted for explanations.

Sometimes dealing with trace functions can become a little bit cumbersome, as can require quite a few
modifications to the source due to precedence rules and need to return the values. There exists a *nifty hack*
to simplify adding debug outputs for trouble-shooting using assertions.

Let's consider this simple example to illustrate:

```
nix-repl> builtins.trace "foo" (if true then true else false)
trace: foo
true

nix-repl> assert builtins.trace "foo" true; if true then true else false
trace: foo
true
```

In the first case parenethesis are necessary to avoid a syntax error. In the
following example of two functions with identical logic it becomes quite visible
that the `assert`-approach can make it easier to add and remove traces with
fewer code changes:

```
  fn1 = a: b:
    builtins.trace "arg a: ${toString a}" (
      if a >= 42 then
        builtins.trace "arg b: ${toString b}" (
          if b >= 23 then
             "best numbers"
          else
            "good"
        )
      else
        "meh"
    );

  fn2 = a: b:
    assert builtins.trace "arg a: ${toString a}" true;
    if a >= 42 then
      assert builtins.trace "arg b: ${toString b}" true;
      if b >= 23 then
         "best numbers"
      else
         "good"
    else
      "meh";
```

## nix-build: keeping code around

[Source dir](./broken_code/)

For this case, lets build the source using `nix-build`;
```
> nix-build -K -E '(import <nixpkgs> {}).callPackage ./broken_code/default.nix {}'
```

To very briefly explain the invocation; Our `default.nix` is in the shape that
most packages in nixpkgs have: a function that takes in some inputs and produces
a derivation. Here the inputs are exclusively the dependencies our derivation has
(`stdenv`) but often there can also be toggles for configuration. Since our
expressions are not located within `nixpkgs` and are not wired up like other
packages, we have to call the functions ourselves in an expression (`-E /
--expr`), using a convenience function which passes us all the required
arguments. We could of course provide default argument values or just import the
files we need manually. This is often less convenient, because it requires
making changes to the nix expression. Using `-K` allows us to keep the build
directory instead of cleaning it up automatically.

Doing this, results in the following output:

```
these derivations will be built:
  /nix/store/3zygyv077brgl52c5gv5vxf81qxbzcl9-hello-0.0.1.drv
building '/nix/store/3zygyv077brgl52c5gv5vxf81qxbzcl9-hello-0.0.1.drv'...
unpacking sources
unpacking source archive /nix/store/1wgzaw3cn4wzxj64v3gal5h42wy6cm8c-broken_code
source root is broken_code
patching sources
configuring
no configure script, doing nothing
building
build flags: SHELL=/nix/store/506nnycf7nk22x7n07mjjjl2g8nifpda-bash-4.4-p23/bin/bash
cc -o hello hello.c
hello.c: In function 'main':
hello.c:5:23: error: expected ';' before '}' token
     printf("Hello!\n")
                       ^
                       ;
 }

make: *** [Makefile:3: hello] Error 1
note: keeping build directory '/tmp/nix-build-hello-0.0.1.drv-0'
builder for '/nix/store/3zygyv077brgl52c5gv5vxf81qxbzcl9-hello-0.0.1.drv' failed with exit code 2
error: build of '/nix/store/3zygyv077brgl52c5gv5vxf81qxbzcl9-hello-0.0.1.drv' failed
```

Here we have a problem building our simple program. Lets for a second imagine that we don't know
why the failure happens.

From the abbreviated output above we see a note that the build outputs are being kept around
in `/tmp/nix-build-hello-0.0.1.drv-0`. The folder contains a file called `env-vars` with the
environment applied during the builder process and our source folder `broken_code`.

This way we can already gain a little bit of insight into the source of the error and inspect
the code as it was actually dowloaded and built.

But if we wanted to actually build this source directly, we will notice that we lack
the requisite environment;

```
> cd /tmp/nix-build-hello-0.0.1.drv-0
> make
The program ‘make’ is currently not installed. It is provided by
several packages. You can install it by typing one of the following:
  nix-env -iA nixos.gnumake
  [...]

> cc
The program ‘cc’ is currently not installed. It is provided by
several packages. You can install it by typing one of the following:
  nix-env -iA nixos.ccacheWrapper
  [...]
```

The next section explains one way to deal with this.

## nix-shell: Getting the build environment

[Source dir](./broken_code/)

If you want to very quickly get the same environment that a derivation had when
being built, you can do so using `nix-shell` to load the produced derivation.

When trying to build our failing derivation, we saw that the derivation itself
was placed in `/nix/store/3zygyv077brgl52c5gv5vxf81qxbzcl9-hello-0.0.1.drv`.
This can now be used to create an environment directly from the derivation. This
is a more convenient method than `nix-shell --pure -p stdenv [.. your other
inputs ..]`. `--pure` ensures that we don't drag in anything undeclared from our
outer environment.

Note that below we invoke `configurePhase` and `buildPhase` instead of
`./configure` and `make` directly - which would also work. To run all phases
automatically `genericBuild` can be used. When using `stdenv`, there are few
things to note; our environment is populated with a bunch of variables from the
derivation and provides set of functions to execute the build.

For more details see [Fundamentals of
Stdenv](https://nixos.org/nixos/nix-pills/fundamentals-of-stdenv.html).

```
> cd /tmp/nix-build-hello-0.0.1.drv-0
> nix-shell --pure /nix/store/3zygyv077brgl52c5gv5vxf81qxbzcl9-hello-0.0.1.drv
[nix-shell:~/projects/nix-drv-1p/broken_code]$ configurePhase
no configure script, doing nothing

[nix-shell:~/projects/nix-drv-1p/broken_code]$ buildPhase
build flags: SHELL=/nix/store/y0slaz23hral5aqmh8msjm5bv3c6hg3w-bash-interactive-4.4-p23/bin/bash
cc -o hello hello.c
hello.c: In function ‘main’:
hello.c:5:23: error: expected ‘;’ before ‘}’ token
     printf("Hello!\n")
                       ^
                       ;
 }
 ~
make: *** [Makefile:3: hello] Error 1
```

Now we can zero-in on the cause of the error, tweak the code or apply some
patches and improve our derivation. This approach also allows to use incremental
builds for debugging purposes.

Another way to achieve a similar result is using `nix repl` to drop into a
`nix-shell` with the correct environment without trying to build the derivation,
just building dependencies and adding them to our environment:

```
> nix repl '<nixpkgs>'
[...]
nix-repl> :s pkgs.callPackage ./broken_code/default.nix {}

[nix-shell:~/projects/nix-drv-1p/test-derivs]$ cd broken_code

[nix-shell:~/projects/nix-drv-1p/test-derivs/01]$ make
cc -o hello hello.c
hello.c: In function ‘main’:
hello.c:5:23: error: expected ‘;’ before ‘}’ token
     printf("Hello!\n")
                       ^
                       ;
 }
 ~
make: *** [Makefile:3: hello] Error 1
```

## Getting into the build sandbox

[Source folder](./breakpoint)

If you suspect that some issue is related to the build sandboxing, it's possible
to use another approach utilizing a breakpoint hook to drop into the actual
build sandbox. Nix executes builds in a sandbox; default since 2.3, on supported
platforms, which is mostly linux. This approach only works on linux and requires
and additional tool `cntr`.

It's actually harder to replicate the build using this approach, but it's nevertheless good to know
when you suspect issues due to the sandbox. For all other issues the other approaches outlined are
probably simpler to troubleshoot most problems.

To use this, we can add `pkgs.breakpointHook` to our [`nativeBuildInputs`](https://github.com/d-goldin/nix-drv-1p/blob/master/breakpoint/default.nix#L8).

```
> nix-build -K -E '(import <nixpkgs> {}).callPackage ./breakpoint/default.nix {}'
[...]
ping -c 1 127.0.0.1
ping: socket: Operation not permitted
make: *** [Makefile:3: hello] Error 1
build failed in buildPhase with exit code 2
To attach install cntr and run the following command as root:

   cntr attach -t command cntr-/nix/store/8l7dfzczkfl984lfn1vgx1wgfxi03g77-hello-0.0.1

```

```
# You might need to create this folder, in case it does not exist already
> sudo mkdir -p /var/lib/cntr
# Entering the container
> sudo cntr attach -t command cntr-/nix/store/8l7dfzczkfl984lfn1vgx1wgfxi03g77-hello-0.0.1

[nixbld@localhost:/var/lib/cntr]$ ls
bin  build  dev  etc  nix  proc  tmp
# We can have a look at what our sandbox consists of and see which namespaces
# are applied.
[nixbld@localhost:/var/lib/cntr]$ lsns
        NS TYPE   NPROCS PID USER   COMMAND
4026531835 cgroup      5   1 nixbld bash -e /nix/store/9krlzvny65gdc8s7kpb6lkx8cd02c25b-default-builder.sh
4026533333 user        5   1 nixbld bash -e /nix/store/9krlzvny65gdc8s7kpb6lkx8cd02c25b-default-builder.sh
4026533334 mnt         3   1 nixbld bash -e /nix/store/9krlzvny65gdc8s7kpb6lkx8cd02c25b-default-builder.sh
4026533335 uts         5   1 nixbld bash -e /nix/store/9krlzvny65gdc8s7kpb6lkx8cd02c25b-default-builder.sh
4026533336 ipc         5   1 nixbld bash -e /nix/store/9krlzvny65gdc8s7kpb6lkx8cd02c25b-default-builder.sh
4026533337 pid         5   1 nixbld bash -e /nix/store/9krlzvny65gdc8s7kpb6lkx8cd02c25b-default-builder.sh
4026533339 net         5   1 nixbld bash -e /nix/store/9krlzvny65gdc8s7kpb6lkx8cd02c25b-default-builder.sh
4026533405 mnt         2  56 nixbld /run/current-system/sw/bin/bash -l
```

This way we have almost everything we need to see what the environment of the build is like and try
out our suspected problem:

```
[nixbld@localhost:/var/lib/cntr]$ ping 127.0.0.1
cannot raise the capability into the Ambient set
: Operation not permitted
```

Turns out we can't ping from the sandbox. We likely need to apply a patch to fix this.

## Resources
* [Nix Manual - The standard environment](https://nixos.org/nixpkgs/manual/#chap-stdenv)
* [nixfmt](https://github.com/serokell/nixfmt)
* [nixfmt web demo](https://nixfmt.serokell.io/)
* [NixOS wiki - create and debug packages](https://nixos.wiki/wiki/Nixpkgs/Create_and_debug_packages)
* [Nixpkgs Manual - Setup hooks](https://nixos.org/nixpkgs/manual/#ssec-setup-hooks)
* [Cntr](https://github.com/Mic92/cntr)
