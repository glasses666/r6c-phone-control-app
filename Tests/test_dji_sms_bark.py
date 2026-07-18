import sys
from pathlib import Path
import unittest


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Scripts"))
from dji_sms_bark import parse_cmgl  # noqa: E402


class DJIMessageParserTests(unittest.TestCase):
    def test_parses_and_decodes_ucs2_message(self):
        output = """@@BEGIN RAW
AT+CMGL=\"ALL\"
+CMGL: 4,\"REC UNREAD\",\"002B00380035003200310032003300340035003600370038\",\"\",\"26/07/18,03:15:00+32\"
77ED4FE1606F5230

OK
@@END RAW
"""

        messages = parse_cmgl(output)

        self.assertEqual(len(messages), 1)
        self.assertEqual(messages[0].index, 4)
        self.assertEqual(messages[0].sender, "+85212345678")
        self.assertEqual(messages[0].body, "\u77ed\u4fe1\u606f\u5230")
        self.assertEqual(messages[0].timestamp, "26/07/18,03:15:00+32")

    def test_preserves_message_body_that_equals_ok(self):
        output = """@@BEGIN RAW
+CMGL: 7,\"REC UNREAD\",\"10086\",\"\",\"26/07/18,03:16:00+32\"
OK

OK
@@END RAW
"""

        messages = parse_cmgl(output)

        self.assertEqual(len(messages), 1)
        self.assertEqual(messages[0].body, "OK")


if __name__ == "__main__":
    unittest.main()
