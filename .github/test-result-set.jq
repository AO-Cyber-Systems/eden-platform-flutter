(map(select(.type=="suite"))
   | map({key:(.suite.id|tostring), value:(.suite.path|sub("^.*/eden-platform-flutter/";""))})
   | from_entries) as $suites
| (map(select(.type=="testStart"))
   | map({key:(.test.id|tostring), value:{name:.test.name, sid:(.test.suiteID|tostring)}})
   | from_entries) as $tests
| map(select(.type=="testDone" and .hidden==false))
| map(. as $d
      | ($tests[($d.testID|tostring)]) as $t
      | "\($d.result)\t\($suites[$t.sid] // "UNKNOWN_SUITE")\t\($t.name)")
| .[]
