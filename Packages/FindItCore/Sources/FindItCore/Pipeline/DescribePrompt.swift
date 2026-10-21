import Foundation

public let describePrompt = """
Describe this screenshot so it can be found later by search. Write 2 to 3 plain sentences in English.
Cover what is present: the people (how many, child or adult, man or woman, pose, expression, accesories), \
their clothing and its colours, the setting and background, notable objects and actions, \
the kind of screen (for example an Instagram post, a WhatsApp chat, TikTok comments, Pinterest, \
a notification screen), and a short summary of any visible text.
Use concrete nouns and colours. Do not guess who people are, do not give opinions, \
and do not start with "The image shows".
In entities, list names, usernames, places, brands and dates exactly as written in the screenshot.
"""

public let describeSchemaJSON = """
    {
    "type": "object",
    "properties": {
        "description": { "type": "string" },
        "category": { "type": "string", "enum": ["people_photo", "other_photo", "chat", "social_media", "notification", "document", "meme", "other"] },
        "language": { "type": "string", "enum": ["en", "es", "mixed", "none"] },
        "entities": { "type": "array", "items": { "type": "string" } }
    },
    "required": ["description", "category", "language", "entities"]
    }
    """

public struct DescribeResult: Decodable, Sendable {
    public let description: String
    public let category: String
    public let language: String
    public let entities: [String]
}

public func decodeDescription(_ json: String) throws -> DescribeResult {
    try JSONDecoder().decode(DescribeResult.self, from: Data(json.utf8))
    }
