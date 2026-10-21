import Testing
@testable import FindItCore

@Test func searchableTextJoinsDescriptionLabelsThenOCR() {
    let text = searchableText(
        ocr: "  Total: $42\nPaid by card\n",
        description: " A receipt from a coffee shop ",
        labels: ["receipt", "", "document"]
    )
    #expect(text == "A receipt from a coffee shop\nreceipt, document\nTotal: $42\nPaid by card")
}

@Test func searchableTextSkipsEmptyOCR() {
    let text = searchableText(ocr: " \n ", description: "A login screen", labels: ["screenshot"])
    #expect(text == "A login screen\nscreenshot")
}
