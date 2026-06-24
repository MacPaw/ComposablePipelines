/// Typical leaf predicate for control flow (`Pipeline` + ``Output`` is ``Bool``).
public protocol BooleanLeaf: LeafPipeline, BooleanPipeline where Output == Bool {}
