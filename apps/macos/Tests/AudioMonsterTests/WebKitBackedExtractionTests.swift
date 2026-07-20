import Testing

/// WebKit-backed tests share process-level browser resources. Keeping them in
/// one serialized hierarchy prevents resource contention without slowing the
/// independent unit-test suites.
@Suite("WebKit-backed extraction", .serialized)
struct WebKitBackedExtractionTests {}
