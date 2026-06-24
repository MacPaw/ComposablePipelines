/// Generates `static var dslPreview: String` from the pipeline's `body` source text at compile time.
@attached(member, names: named(dslPreview))
public macro PipelinePreview() = #externalMacro(module: "PipelinePreviewMacro", type: "PipelinePreviewMacro")
