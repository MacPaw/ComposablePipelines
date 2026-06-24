import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct PipelinePreviewMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf decl: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let bodyVar = decl.memberBlock.members
            .compactMap { $0.decl.as(VariableDeclSyntax.self) }
            .first { $0.bindings.first?.pattern.trimmedDescription == "body" }

        guard
            let bodyVar,
            let binding = bodyVar.bindings.first,
            let accessorBlock = binding.accessorBlock
        else { return [] }

        let stmtsText: String
        switch accessorBlock.accessors {
        case .getter(let stmts):
            stmtsText = stmts.description
        default:
            return []
        }

        let deindented = deindent(stmtsText)

        return [
            """
            static var dslPreview: String {
                \(literal: deindented)
            }
            """
        ]
    }

    private static func deindent(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let minIndent = nonEmpty.map({ $0.prefix(while: { $0 == " " }).count }).min(), minIndent > 0 else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let prefix = String(repeating: " ", count: minIndent)
        return lines
            .map { $0.hasPrefix(prefix) ? String($0.dropFirst(minIndent)) : $0 }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@main
struct PipelinePreviewMacroPlugin: CompilerPlugin {
    let providingMacros: [any Macro.Type] = [PipelinePreviewMacro.self]
}
