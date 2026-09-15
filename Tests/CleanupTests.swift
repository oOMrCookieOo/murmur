import Foundation

/// Safety tests for the cleanup layer.
///
/// These are the guards that stand between the user's words and a language
/// model that might decide to answer them instead of tidying them. Every
/// "REJECT" case below was accepted by an earlier version of `isFaithful`, and
/// every corruption case below was produced by an earlier `stripFillers`.
///
/// Run with `make test`.
@main
struct CleanupTests {

    static func main() {
        var failures = 0
        let en = Locale(identifier: "en-US")

        func faithful(_ original: String, _ candidate: String, _ want: Bool, _ label: String) {
            let got = TranscriptCleaner.isFaithful(original: original, candidate: candidate)
            guard got != want else {
                print("PASS  [\(label)]")
                return
            }
            failures += 1
            print("FAIL  [\(label)] want=\(want ? "accept" : "REJECT") got=\(got ? "accept" : "REJECT")")
            print("        orig: \(original)")
            print("        cand: \(candidate)")
        }

        func strip(_ input: String, _ want: String, _ locale: Locale = en) {
            let got = TranscriptCleaner.stripFillers(from: input, locale: locale)
            guard got != want else {
                print("PASS  \"\(input)\" -> \"\(got)\"")
                return
            }
            failures += 1
            print("FAIL  \"\(input)\" -> \"\(got)\"  (wanted \"\(want)\")")
        }

        print("=== isFaithful: the model must not be allowed to rewrite meaning ===")
        faithful("what is the capital of france",
                 "The capital of France is Paris.", false, "model answered the question")
        faithful("the quick brown fox jumps over the lazy dog near the river bank at dawn",
                 "The quick brown fox jumps over the lazy dog.", false, "tail clause dropped")
        faithful("i will not be attending the meeting tomorrow morning",
                 "I will be attending the meeting tomorrow morning.", false, "negation flipped")
        faithful("send it to john at 5 and to mary at 7",
                 "Send it to john at 7 and to mary at 5.", false, "numbers swapped")
        faithful("please review the document",
                 "Sure! Here is the corrected version: Please review the document.", false, "chatbot preamble")

        print("\n=== isFaithful: legitimate cleanups must still be accepted ===")
        faithful("um so i think we should ship it tomorrow",
                 "So I think we should ship it tomorrow.", true, "filler + capitalisation")
        faithful("hello world this is a test",
                 "Hello, world. This is a test.", true, "punctuation added")
        faithful("i dont think thats right",
                 "I don't think that's right.", true, "contractions restored")
        faithful("the meeting is at 5 on tuesday",
                 "The meeting is at 5 on Tuesday.", true, "number preserved")
        faithful("uh we need to fix the the parser bug",
                 "We need to fix the parser bug.", true, "stutter removed")

        print("\n=== stripFillers: must not corrupt real words ===")
        strip("The bolt is 5 mm wide", "The bolt is 5 mm wide")
        strip("Set margin to 2 mm, padding 4 mm.", "Set margin to 2 mm, padding 4 mm.")
        strip("Hmm. Let me think.", "Let me think.")
        strip("Dr. Ah Meng visited", "Dr. Ah Meng visited")
        strip("The prefix er- is Germanic", "The prefix er- is Germanic")
        strip("value: er", "value: er")
        strip("ah ah ah", "ah ah ah")
        strip("Er ist mein Bruder und er kommt heute",
              "Er ist mein Bruder und er kommt heute", Locale(identifier: "de-DE"))

        print("\n=== stripFillers: real fillers must still go ===")
        strip("um hello there", "hello there")
        strip("So, um, I think so.", "So, I think so.")
        strip("uh yeah uhm sure", "yeah sure")

        print("")
        if failures == 0 {
            print("ALL PASS")
        } else {
            print("\(failures) FAILURE(S)")
            exit(1)
        }
    }
}
