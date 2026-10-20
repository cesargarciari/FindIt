import ArgumentParser

@main
struct FindItEval: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "findit-eval")

    func run() throws {
        print("findit-eval ready")
    }
}
