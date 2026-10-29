/// Serializes all lwext4 calls (the library has global, non-thread-safe state).
@globalActor
public actor LwExt4 {
    public static let shared = LwExt4()
}
