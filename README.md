"Univeral Lambda" for Zig
=========================

This a Zig 0.11 project intended to be used as a package to turn a zig program
into a function that can be run as:

* A command line executable
* A standalone web server
* An AWS Lambda function
* A shared library in [flexilib](https://git.lerch.org/lobo/FlexiLib)
* Cloudflare
* etc

Usage - Development
-------------------

From an empty directory, with Zig 0.11 installed:

`zig init-exe`


Create a `build.zig.zon` with the following contents:

```
.{
    .name = "univeral-zig-example",
    .version = "0.0.1",

    .dependencies = .{
        .universal_lambda_build = .{
            .url = "https://git.lerch.org/lobo/universal-lambda-zig/archive/70b0fda03b9c54a6eda8d61cb8ab8b9d9f29b2ef.tar.gz",
            .hash = "122004f2a4ad253be9b8d7989ca6508af1483d8a593ca7fee93627444b2b37d170d2",
        },
        .flexilib = .{
            .url = "https://git.lerch.org/lobo/flexilib/archive/c44ad2ba84df735421bef23a2ad612968fb50f06.tar.gz",
            .hash = "122051fdfeefdd75653d3dd678c8aa297150c2893f5fad0728e0d953481383690dbc",
        },
    },
}
```

Due to limitations in the build apis related to relative file paths, the
dependency name currently must be "universal_lambda_build". Also, note that
the flexilib dependency is required at all times. This requirement may go away
with zig 0.12 (see [#17135](https://github.com/ziglang/zig/issues/17135))
and/or changes to this library.

**Build.zig:**

* Add an import at the top:

```zig
const configureUniversalLambdaBuild = @import("universal_lambda_build").configureBuild;
```

* Set the return of the build function to return `!void` rather than `void`
* Add a line to the build script, after any modules are used, but otherwise just
  after adding the exe is fine:

```zig
try configureUniversalLambdaBuild(b, exe);
```

This will provide most of the magic functionality of the package, including
several new build steps to manage the system, and a new import to be used.

**main.zig**

The build changes above will add a module called 'universal_lambda_handler'.
Add an import:

```zig
const universal_lambda = @import("universal_lambda_handler");
```

Add a handler to be executed. **This must be public, and named 'handler'**.
If you don't want to do that, name it whatever you want, and provide a public
const, e.g. `pub const handler=myActualFunctionName`. The handler must
follow this signature:

```zig
pub fn handler(allocator: std.mem.Allocator, event_data: []const u8, context: universal_lambda.Context) ![]const u8
```

Let the package know about your handler in your main function, like so:

```zig
try universal_lambda.run(null, handler);
```

The first parameter above is an allocator. If you have a specific handler you
would like to use, you may specify it. Otherwise, an appropriate allocator
will be created and used. Currently this is an ArenaAllocator wrapped around
an appropriate base allocator, so your handler does not require deallocation.

Note that for `flexilib` builds, the main function is ignored and the handler
is called directly. This is unique to flexilib.

A fully working example of usage is at https://git.lerch.org/lobo/universal-lambda-example/.


Usage - Building
----------------

The build configuration will add the following build steps when building with
Linux:

```
  awslambda_package            Package the function
  awslambda_deploy             Deploy the function
  awslambda_iam                Create/Get IAM role for function
  awslambda_run                Run the app in AWS lambda
  cloudflare                   Deploy as Cloudflare worker (must be compiled with -Dtarget=wasm32-wasi)
  flexilib                     Create a flexilib dynamic library
  standalone_server            Run the function in its own web server
```

AWS Lambda is not currently available if building with other operating systems,
as that set of build steps utilize system commands using the AWS CLI. This is
likely to change in the future to enable other operating systems. All other
build steps are available for all targets.

Note that AWS Lambda will require that credentials are established using the
same methods as checked by the AWS CLI and the AWS CLI is installed.

If using Cloudflare deployment, either CLOUDFLARE_API_TOKEN or
CLOUDFLARE_EMAIL/CLOUDFLARE_API_KEY environment variables must be set for
successful deployment.

To run as an executable, a simple `zig build` will build, or `zig build run`
will run as expected. `zig build standalone_server run` will also build/run
as a standalone web server.

Limitations
-----------

This is currently a minimal viable product. The biggest current limitation
is that context is not currently implemented. This is important to see
command line arguments, http headers and the like.

Other limitations include standalone web server port customization, main
function not called under flexilib, and linux/aws cli requirements for Linux.
