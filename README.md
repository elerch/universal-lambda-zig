"Univeral Lambda" for Zig
=========================

This a Zig 0.12 project intended to be used as a package to turn a zig program
into a function that can be run as:

* A command line executable
* A standalone web server
* An AWS Lambda function
* A shared library in [flexilib](https://git.lerch.org/lobo/FlexiLib)
* Cloudflare
* etc

Usage - Development
-------------------

From an empty directory, with Zig 0.12 installed:

```sh
zig init-exe
zig fetch --save https://git.lerch.org/lobo/universal-lambda-zig/archive/9b4e1cb5bc0513f0a0037b76a3415a357e8db427.tar.gz
```

**Build.zig:**

* Add an import at the top:

```zig
const universal_lambda = @import("universal-lambda-zig");
```

* Set the return of the build function to return `!void` rather than `void`
* Add a line to the build script, after any modules are used, but otherwise just
  after adding the exe is fine. Imports will also be added through universal_lambda:

```zig
const univeral_lambda_dep = b.dependency("universal-lambda-zig", .{
    .target = target,
    .optimize = optimize,
});
try universal_lambda.configureBuild(b, exe, univeral_lambda_dep);
_ = universal_lambda.addImports(b, exe, univeral_lambda_dep);
```

This will provide most of the magic functionality of the package, including
several new build steps to manage the system, as well as imports necessary
for each of the providers. Note that addImports should also be called for
unit tests.

```zig
_ = universal_lambda.addImports(b, unit_tests, univeral_lambda_dep);
```

**main.zig**

`addImports` will make the following primary imports available for use:

* universal_lambda_handler: Main import, used to register your handler
* universal_lambda_interface: Contains the context type used in the handler function

Additional imports are available and used by the universal lambda runtime, but
should not normally be needed for direct use:

* flexilib-interface: Used as a dependency of the handler
* universal_lambda_build_options: Provides the ability to determine which provider is used
                                  The build type is stored under a `build_type` variable.
* aws_lambda_runtime: Provides the aws lambda provider access to the underlying library

Add imports for the handler registration and interface:

```zig
const universal_lambda = @import("universal_lambda_handler");
const universal_lambda_interface = @import("universal_lambda_interface");
```

Add a handler to be executed. The handler must follow this signature:

```zig
pub fn handler(allocator: std.mem.Allocator, event_data: []const u8, context: universal_lambda_interface.Context) ![]const u8
```

Your main function should return `!u8`. Let the package know about your handler in your main function, like so:

```zig
return try universal_lambda.run(null, handler);
```

The first parameter above is an allocator. If you have a specific allocator you
would like to use, you may specify it. Otherwise, an appropriate allocator
will be created and used. Currently this is an ArenaAllocator wrapped around
an appropriate base allocator, so your handler does not require deallocation.

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

Limitations include standalone web server port customization and linux/aws cli requirements for Linux.

Also, within the context, AWS Lambda is unable to provide proper method, target,
and headers for the request. This may be important for routing purposes. Suggestion
here is to use API Gateway and pass these parameters through the event_data content.

Lastly, support for specifying multiple targets in the downstream (your) application
is somewhat spotty. For example, `zig build standalone_server run` works fine.
However, `zig build test flexilib` is broken.
