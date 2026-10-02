# -*- coding: utf-8 -*-
from __future__ import absolute_import, annotations, print_function

import unittest

from sms import _parse_smsbackup_content


class TestSMSBackupParser(unittest.TestCase):
    def test_parse_smsbackup_content_multipart(self):
        sample_backup = """
; This file format was designed for Gammu and is compatible with Gammu+
; See <http://www.gammu.org> for more info
; Saved 20261002T034347 (Fri 02 Oct 2026 03:43:47 AM )

[SMSBackup000]
SMSC = "+550050114257"
SMSCUnicode = 002B003500350030003000350030003100310034003200350037
PDU = Deliver
DateTime = 20261002T034337
State = UnRead
Number = "2650011"
NumberUnicode = 0032003600350030003000310031
Name = ""
NameUnicode =
UDH = 050003400201
Text00 = 0042006F006F006B0069006E006700200063006F006E0066006F0072006D006100740069006F006E0020007000720065006600690078000A00480069002C000A000A0059006F0075007200200062006F006F006B0069006E006700200061007400200055
Text01 = 004B005400610062006C00650042006F006F006B0069006E006700200069007300200063006F006E006600690072006D00650064002E000A000A005700680065006E003A0020004600720069006400610079002000320020004F00630074006F00620065
Text02 = 007200200032003000320036002C002000310031003A00310035000A000A004D0061006E00610067006500200079006F0075007200200062006F006F006B0069006E0067000A00680074007400700073003A002F002F0062006F006F006B0069006E0067
Text03 = 002E00740065
Coding = Default_No_Compression
Folder = 1
Length = 153
Class = -1
ReplySMSC = False
RejectDuplicates = False
ReplaceMessage = 0
MessageReference = 0

[SMSBackup001]
SMSC = "+550050114257"
SMSCUnicode = 002B003500350030003000350030003100310034003200350037
PDU = Deliver
DateTime = 20261002T034338
State = UnRead
Number = "2650011"
NumberUnicode = 0032003600350030003000310031
Name = ""
NameUnicode =
UDH = 050003400202
Text00 = 0073007400650070006F0073006E006F007700680071002E0063006F006D002F0062006F006F006B0069006E0067002F006D0061006E006100670065002F0035006B003900750066003400720067000A0042006F006F006B0069006E006700200063006F
Text01 = 006E0066006F0072006D006100740069006F006E0020007300750066006600690078
Coding = Default_No_Compression
Folder = 1
Length = 67
Class = -1
ReplySMSC = False
RejectDuplicates = False
ReplaceMessage = 0
MessageReference = 0
"""
        sender, text = _parse_smsbackup_content(sample_backup)
        self.assertEqual(sender, "2650011")
        expected = (
            "Booking conformation prefix\n"
            "Hi,\n\n"
            "Your booking at UKTableBooking is confirmed.\n\n"
            "When: Friday 2 October 2026, 11:15\n\n"
            "Manage your booking\n"
            "https://booking.testeposnowhq.com/booking/manage/5k9uf4rg\n"
            "Booking conformation suffix"
        )
        self.assertEqual(text, expected)


if __name__ == "__main__":
    unittest.main()
