"Univeral Lambda" for Zig
=========================

This a Zig 0.11 project intended to be used as a package to turn a zig program
into a function that can be run as:

* A command line executable
* A standalone web server
* An AWS Lambda function
* A shared library in [flexilib](https://git.lerch.org/lobo/FlexiLib)
* Cloudflare (TODO/Planned)
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
            .url = "https://git.lerch.org/lobo/universal-lambda-zig/archive/ff691a439105ca6800757a39c208c11fcdabb058.tar.gz",
            .hash = "12205386f7353907deb7f195d920bc028e0e73f53dcd23c5e77210a39b31726bf46f",
        },
    },
}
```

Due to limitations in the build apis related to relative file paths, the
dependency name currently must be "universal_lambda_build".

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
  standalone_server            Run the function in its own web server
  flexilib                     Create a flexilib dynamic library
```

AWS Lambda is not currently available if building with other operating systems,
as that set of build steps utilize system commands using the AWS CLI. This is
likely to change in the future to enable other operating systems.

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
