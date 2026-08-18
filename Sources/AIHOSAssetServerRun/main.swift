import AIHOSAssetServer

// Program entry point, and deliberately nothing else.
//
// Every line of server behaviour — configuration, migrations, routes, the machine auth
// gate — lives in the AIHOSAssetServer library so it can be imported and tested. This
// file exists only because an executable target needs an entry point and a module that
// has one cannot be imported by the test bundle.
//
// Keep it this small. Anything added here would be production code that no test can
// reach, which is exactly the situation the split was made to end.

try await AIHOSAssetServer.main()
