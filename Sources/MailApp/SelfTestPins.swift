#if TESTHARNESS
import Foundation
import ImageIO
import AppKit
import MailCore

extension SelfTest {
    static func partPins() async -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) { print((cond ? "PASS " : "FAIL ") + name); if !cond { ok = false } }
        // pins: a Gmail label, created on first pin, added and removed with one batch call each (stubbed Gmail, nothing real touched)
        // away message: Gmail's vacation settings, stubbed (John's real setting is never touched)
        do {
            var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
            var a = AwaySettings(); a.on = true; a.first = Date(timeIntervalSince1970: 1_791_936_000); a.last = a.first.addingTimeInterval(6 * 86400)
            a.subject = "Away"; a.body = "Back soon"; a.contactsOnly = true; a.plainAtLoad = a.body
            let j = a.json(cal: cal), back = AwaySettings(json: j, cal: cal)
            check("away: Gmail fields sent (on, times in ms, subject, text, contacts only); end is the midnight after the last day",
                  j["enableAutoReply"] as? Bool == true && j["responseSubject"] as? String == "Away" && j["responseBodyPlainText"] as? String == "Back soon" && j["restrictToContacts"] as? Bool == true
                  && j["startTime"] as? String == String(Int64(a.first.timeIntervalSince1970 * 1000)) && j["endTime"] as? String == String(Int64(a.first.addingTimeInterval(7 * 86400).timeIntervalSince1970 * 1000)))
            var a2 = a; a2.rawStart = j["startTime"] as? String; a2.rawEnd = j["endTime"] as? String
            check("away: Gmail's answer reads back into the same settings", back == a2)
            var noEnd = a; noEnd.last = nil
            check("away: until I turn it off sends no end time", noEnd.json(cal: cal)["endTime"] == nil && AwaySettings(json: noEnd.json(cal: cal), cal: cal).last == nil)
            var empty = a; empty.subject = " "; empty.body = ""
            var backwards = a; backwards.last = a.first.addingTimeInterval(-86400)
            check("away: on with no subject and no text, or a last day before the first, is refused", empty.problem(cal: cal) != nil && backwards.problem(cal: cal) != nil && a.problem(cal: cal) == nil)
            check("away: strip shows while on and the last day has not passed, never when off or past",
                  a.showsStrip(now: a.first, cal: cal) && !a.showsStrip(now: a.first.addingTimeInterval(8 * 86400), cal: cal) && noEnd.showsStrip(now: a.first.addingTimeInterval(900 * 86400), cal: cal) && !AwaySettings().showsStrip()
                  && !a.showsStrip(now: a.first.addingTimeInterval(-3600), cal: cal))
            check("away: strip text names the last day (with the year when not this year) or just says it is on", noEnd.stripText() == "Away message is on" && a.stripText(now: a.first, cal: cal).hasPrefix("Away message is on until ")
                  && !a.stripText(now: a.first, cal: cal).contains("2026") && a.stripText(now: a.first.addingTimeInterval(400 * 86400), cal: cal).contains("2026"))
            // what Gmail holds that the form cannot edit survives a save: HTML-only body, domain limit, an end time that is not midnight
            let odd = #"{"enableAutoReply":true,"responseSubject":"S","responseBodyHtml":"<b>Hi</b>","restrictToDomain":true,"startTime":"1791936000000","endTime":"1792100000000"}"#
            let held = AwaySettings(json: try! JSONSerialization.jsonObject(with: Data(odd.utf8)) as! [String: Any], cal: cal), hj = held.json(cal: cal)
            var edited = held; edited.body = "New text"
            var movedEnd = held; movedEnd.last = held.last!.addingTimeInterval(86400)
            var off = held; off.on = false
            check("away: an HTML-only message, the domain limit and a non-midnight end time are sent back unchanged",
                  held.body.isEmpty && held.problem(cal: cal) == nil && hj["responseBodyHtml"] as? String == "<b>Hi</b>" && hj["restrictToDomain"] as? Bool == true && hj["endTime"] as? String == "1792100000000" && hj["startTime"] as? String == "1791936000000")
            check("away: typing a new text drops the HTML, moving the last day replaces the end time",
                  edited.json(cal: cal)["responseBodyHtml"] == nil && edited.json(cal: cal)["responseBodyPlainText"] as? String == "New text" && movedEnd.json(cal: cal)["endTime"] as? String != "1792100000000")
            var offBad = backwards; offBad.on = false
            check("away: turning off is never blocked by the dates or an empty text", off.problem(cal: cal) == nil && offBad.problem(cal: cal) == nil && offBad.json(cal: cal)["enableAutoReply"] as? Bool == false)
            // an old away message left in Gmail (John's account held 3 June 2015, off) shows today; real dates and a running message are kept
            let old2015 = "1433311200000", today = a.first
            let staleOff = AwaySettings(json: ["enableAutoReply": false, "startTime": old2015], cal: cal, now: today)
            let staleEnd = AwaySettings(json: ["enableAutoReply": false, "startTime": old2015, "endTime": "1433400000000"], cal: cal, now: today)
            let staleOn = AwaySettings(json: ["enableAutoReply": true, "startTime": old2015], cal: cal, now: today)
            let laterOff = AwaySettings(json: ["enableAutoReply": false, "startTime": j["startTime"] as! String], cal: cal, now: today.addingTimeInterval(-86400))
            let offShowsToday: Bool = staleOff.first == today && staleOff.last == nil && staleEnd.first == today && staleEnd.last == today
            let realKept: Bool = staleOn.first < today && laterOff.first == today
            check("away: an old 2015 date shows as today while off; a running message and a future day are kept", offShowsToday && realKept)
            nonisolated(unsafe) var seen: [String] = []
            nonisolated(unsafe) var reply: (Int, String) = (200, #"{"enableAutoReply":true,"responseSubject":"Hi","responseBodyPlainText":"x","restrictToContacts":false}"#)
            StubProtocol.handler = { req in
                let u = req.url!.absoluteString
                if u.contains("oauth2") || u.contains("token") && !u.contains("gmail") { return (200, #"{"access_token":"AT","expires_in":3600}"#) }
                seen.append("\(req.httpMethod ?? "") \(req.url!.path) \(String(data: req.httpBody ?? Data(), encoding: .utf8) ?? "")")
                return reply
            }
            let gc = GmailClient(auth: pauth, session: session)
            var got: AwaySettings?
            do { got = try await gc.vacation(); try await gc.setVacation(a) } catch { check("away: stubbed read and write ran without an error (\(error))", false) }
            check("away: reads from and writes to Gmail's vacation settings (GET then PUT), start and end times included",
                  got?.on == true && got?.subject == "Hi" && seen.count == 2 && seen[0].hasPrefix("GET /gmail/v1/users/me/settings/vacation") && seen[1].hasPrefix("PUT /gmail/v1/users/me/settings/vacation") && seen[1].contains("responseSubject")
                  && seen[1].contains("startTime") && seen[1].contains("endTime"))
            // an HTML-only reply from Gmail is kept on the way back out, and a failed read throws instead of giving a blank form
            seen = []; reply = (200, odd)
            do { let h = try await gc.vacation(); try await gc.setVacation(h) } catch { check("away: HTML-only round trip ran without an error (\(error))", false) }
            check("away: an HTML-only message from Gmail is written back with its HTML", seen.count == 2 && seen[1].contains("responseBodyHtml") && seen[1].contains("Hi") && seen[1].contains("restrictToDomain"))
            reply = (403, "{}")
            var readFailed = false
            do { _ = try await gc.vacation() } catch { readFailed = true }
            check("away: a failed read throws, so the form never shows a blank to save over a running message", readFailed)
            reply = (200, "not json")
            readFailed = false
            do { _ = try await gc.vacation() } catch { readFailed = true }
            check("away: an unreadable answer throws too", readFailed)
            StubProtocol.handler = nil
        }
        // big files by link: Drive upload, sharing, expiry and deletion, stubbed (nothing real is uploaded)
        do {
            let t0 = Date(timeIntervalSince1970: 1_791_936_000)
            let day: TimeInterval = 86400
            let labels: [String] = BigFileExpiry.allCases.map(\.label)
            let e3: Date? = BigFileExpiry.days3.end(from: t0), e30: Date? = BigFileExpiry.days30.end(from: t0), eNever: Date? = BigFileExpiry.never.end(from: t0)
            let expiryOK: Bool = labels == ["3 days", "7 days", "30 days", "Never"] && e3 == t0.addingTimeInterval(3 * day) && e30 == t0.addingTimeInterval(30 * day) && eNever == nil
            check("big file: expiry choices are 3, 7, 30 days and Never (no end time)", expiryOK)
            let hh = BigFile.html([("A <b>.zip", 50_000_000, "FID")], expiry: .never), h7 = BigFile.html([("a.zip", 5, "F")], expiry: .days7)
            let linkURL = "https://drive.google.com/file/d/FID/view"
            let htmlOK: Bool = hh.contains("A &lt;b&gt;.zip") && hh.contains(linkURL) && hh.contains("no expiry") && hh.contains(">Download</a>") && h7.contains("available for 7 days") && !h7.contains("no expiry")
            let plainOK: Bool = TextTools.htmlToPlain(hh).contains(linkURL)
            check("big file: the email block names the file (escaped), its Drive link, and shows size and expiry on a card with a Download link", htmlOK && plainOK)
            let fa = DriveFile(id: "a", name: "a", deleteAt: t0), fb = DriveFile(id: "b", name: "b", deleteAt: t0.addingTimeInterval(1))
            let dueIDs: [String] = BigFile.due([fa, fb], now: t0).map(\.id)
            check("big file: only files past their time are due", dueIDs == ["a"])
            let old = try? JSONDecoder().decode(TimingData.self, from: Data(#"{"snoozes":{},"scheduled":[],"followUps":[],"surfaced":{},"noReply":[]}"#.utf8))
            let oldOK: Bool = old != nil && old?.bigFiles == nil
            check("big file: a timing file from before this feature still loads", oldOK)
            let bf = FileManager.default.temporaryDirectory.appendingPathComponent("bigfile-\(UUID().uuidString).bin"); try? Data("0123456789".utf8).write(to: bf)
            defer { try? FileManager.default.removeItem(at: bf) }
            nonisolated(unsafe) var seen: [String] = []
            nonisolated(unsafe) var permCode = 200, permBody = "{}", permN = 0, permFailFrom = 99, delCode = 200
            nonisolated(unsafe) var upID = "FID1"
            StubProtocol.headers = ["Location": "https://www.googleapis.com/upload/session/xyz"]
            StubProtocol.handler = { req in
                let u = req.url!.absoluteString
                if u.contains("oauth2") || u.contains("token") && !u.contains("gmail") { return (200, #"{"access_token":"AT","expires_in":3600}"#) }
                seen.append("\(req.httpMethod ?? "") \(req.url!.path) \(String(data: req.httpBody ?? Data(), encoding: .utf8) ?? "")")
                if req.httpMethod == "DELETE" && delCode != 200 { return (delCode, "{}") }
                if u.contains("/permissions") { permN += 1; return permN >= permFailFrom ? (500, "{}") : (permCode, permBody) }
                if u.contains("upload/session") { return (200, "{\"id\":\"\(upID)\"}") }
                return (200, "{}")
            }
            let gc = GmailClient(auth: pauth, session: session)
            let id = try? await gc.driveUpload(bf)
            let upOK: Bool = seen.count == 3 && seen[0].hasPrefix("POST /upload/drive/v3/files") && seen[0].contains(bf.lastPathComponent) && seen[1].hasPrefix("PUT /upload/session/xyz")
            let shareOK: Bool = seen.count == 3 && seen[2].hasPrefix("POST /drive/v3/files/FID1/permissions") && seen[2].contains("anyone") && seen[2].contains("reader")
            check("big file: uploads in two steps, then opens it to anyone with the link as a reader", id == "FID1" && upOK && shareOK)
            seen = []; permCode = 500
            var failed = false
            do { _ = try await gc.driveUpload(bf) } catch { failed = true }
            let lastCall: String = seen.last ?? ""
            check("big file: if sharing fails the uploaded file is deleted again and the error is thrown", failed && lastCall.hasPrefix("DELETE /drive/v3/files/FID1"))
            permCode = 403; permBody = #"{"error":{"message":"Insufficient Permission"}}"#
            var needs = false
            do { _ = try await gc.driveUpload(bf) } catch BigFileError.needsPermission { needs = true } catch {}
            check("big file: an old sign-in without the Drive permission says to sign in again", needs)
            permCode = 200; permBody = "{}"; seen = []
            let tf = FileManager.default.temporaryDirectory.appendingPathComponent("bigfile-t-\(UUID().uuidString).json"); defer { try? FileManager.default.removeItem(at: tf) }
            let st = await MainActor.run { MailStore(auth: SignInModel(), gmail: gc, book: SenderBook(url: cbURL.appendingPathExtension("bf")), seen: SeenBook(url: cbURL.appendingPathExtension("bfs")), categories: CategoryBook(url: nil), asides: AsideBook(url: nil), organizer: OrganizerBook(url: nil), timing: TimingBook(url: tf)) }
            let pick = BigFilePick(url: bf, size: 10), pickN = BigFilePick(url: bf, size: 10, expiry: .never)
            let blockHTML = try? await st.uploadBigFiles([pick])
            let kept = await MainActor.run { st.timing.data.bigFiles ?? [] }
            upID = "FID2"   // a different id, so the timed record and the Never record stay apart
            _ = try? await st.uploadBigFiles([pickN])
            upID = "FID1"
            let keptNever = await MainActor.run { st.timing.data.bigFiles ?? [] }
            let htmlHasID: Bool = blockHTML?.contains("FID1") ?? false
            let secondsOut: Double = (kept.first?.deleteAt.timeIntervalSinceNow ?? 0) - 7 * day
            check("big file: a timed link is remembered for deletion 7 days out; Never is remembered with no end time", htmlHasID && kept.count == 1 && kept.first?.id == "FID1" && abs(secondsOut) < 60 && keptNever.count == 2 && keptNever.last?.id == "FID2" && keptNever.last?.deleteAt == BigFile.neverAt)
            let before = await MainActor.run { st.timing.data.bigFiles ?? [] }
            let mixed = try? await st.uploadBigFiles([BigFilePick(url: bf, size: 10, expiry: .days3), BigFilePick(url: bf, size: 10, expiry: .never)])
            let mixedOK: Bool = (mixed?.contains("available for 3 days") ?? false) && (mixed?.contains("no expiry") ?? false)
            check("big file: each file keeps its own expiry in the email", mixedOK)
            await MainActor.run { st.timing.change { $0.bigFiles = before } }   // the stub gives repeated ids, so put the records back
            seen = []
            await st.deleteExpiredBigFiles(now: Date().addingTimeInterval(6 * 86400))
            let early = await MainActor.run { st.timing.data.bigFiles?.count }
            check("big file: nothing is deleted before its time", seen.isEmpty && early == 2)
            await st.deleteExpiredBigFiles(now: Date().addingTimeInterval(8 * 86400))
            let late = await MainActor.run { st.timing.data.bigFiles ?? [] }
            let delCall: String = seen.first ?? ""
            check("big file: at its time the file is deleted from Drive and forgotten (a Never file stays)", seen.count == 1 && delCall.hasPrefix("DELETE /drive/v3/files/FID1") && late.count == 1 && late.first?.deleteAt == BigFile.neverAt)
            // the Sent-email strip and Delete now
            let sentHTML = "<p>hi</p>" + BigFile.html([("n", 1, "FID2")], expiry: .never)
            let sNever: [BigFile.Strip] = BigFile.strips(html: sentHTML, records: late, now: Date())
            let sTimed: [BigFile.Strip] = BigFile.strips(html: sentHTML, records: [DriveFile(id: "FID2", name: "a", deleteAt: Date().addingTimeInterval(3 * day - 60))], now: Date())
            let sNone: [BigFile.Strip] = BigFile.strips(html: "<p>no link</p>", records: late, now: Date())
            let sQuoted: [BigFile.Strip] = BigFile.strips(html: "<p>thanks</p><blockquote class=\"gmail_quote\">" + BigFile.html([("n", 1, "FID2")], expiry: .never) + "</blockquote>", records: late, now: Date())
            check("big file: the Sent strip says Stays in your Drive, or Deletes in N days, and only shows on the email that carries the link, not on a reply that quotes it", sNever.first?.text == "Stays in your Drive" && sTimed.first?.text == "Deletes from your Drive in 3 days" && sNone.isEmpty && sQuoted.isEmpty)
            seen = []
            let nowOK = await st.deleteBigFileNow("FID2")
            let afterNow = await MainActor.run { st.timing.data.bigFiles ?? [] }
            let nowCall: String = seen.first ?? ""
            check("big file: Delete now removes the file from Drive and forgets the record", nowOK && nowCall.hasPrefix("DELETE /drive/v3/files/FID2") && afterNow.isEmpty)
            permN = 0; permFailFrom = 99
            _ = try? await st.uploadBigFiles([pickN])
            delCode = 500
            let nowFail = await st.deleteBigFileNow("FID1")
            let afterFail = await MainActor.run { st.timing.data.bigFiles ?? [] }
            delCode = 200
            check("big file: if Delete now fails the record stays, due now, for the next sweep", !nowFail && afterFail.count == 1 && (afterFail.first?.deleteAt ?? .distantFuture) <= Date())
            await MainActor.run { st.timing.change { $0.bigFiles = [] } }
            // second file fails to upload and the clean-up delete of the first also fails: the record stays, due now, so the sweep retries
            permN = 0; permFailFrom = 2; delCode = 500
            _ = try? await st.uploadBigFiles([pick, pick])
            let stuck = await MainActor.run { st.timing.data.bigFiles ?? [] }
            delCode = 200; seen = []
            await st.deleteExpiredBigFiles(now: Date().addingTimeInterval(5))
            let swept = await MainActor.run { st.timing.data.bigFiles?.count }
            check("big file: if the clean-up delete fails the record is kept, due now; the next sweep deletes it", stuck.count == 2 && stuck.allSatisfy { $0.id == "FID1" } && abs(stuck.first?.deleteAt.timeIntervalSinceNow ?? 99) < 60 && seen.count == 2 && swept == 0)   // 2: the stub gives both uploads the same id; the failing second one is recorded too
            // share step fails and its own clean-up delete fails too: the file is recorded, due now
            permN = 0; permFailFrom = 1; delCode = 500
            let stErr = await MainActor.run { st.timing.change { $0.bigFiles = [] } }; _ = stErr
            var gotStuck = false
            do { _ = try await st.uploadBigFiles([pickN]) } catch BigFileError.stuck { gotStuck = true } catch {}
            let kept2 = await MainActor.run { st.timing.data.bigFiles ?? [] }
            delCode = 200
            check("big file: if sharing fails and the clean-up delete fails too, the file is still recorded (due now)", gotStuck && kept2.count == 1 && kept2.first?.id == "FID1" && abs(kept2.first?.deleteAt.timeIntervalSinceNow ?? 99) < 60)
            check("big file: send later is refused with a plain message while a big file is attached", BigFileLater.problem(bigFileCount: 1) == "Big files can't be sent later yet. Send now, or remove the file." && BigFileLater.problem(bigFileCount: 0) == nil)
            StubProtocol.handler = nil; StubProtocol.headers = nil
        }
        // rules: Gmail filters in plain words, stubbed (John's real filters are never touched)
        do {
            func filter(_ j: String) -> GFilter { try! JSONDecoder().decode(GFilter.self, from: Data(j.utf8)) }
            let names = ["Label_1": "Shopping", "Label_2": "Blocked"], user = Set(names.keys)
            let mine = filter(#"{"id":"f1","criteria":{"from":"news@shop.com","hasAttachment":true},"action":{"addLabelIds":["Label_1","STARRED"],"removeLabelIds":["INBOX","UNREAD","SPAM"]}}"#)
            let r = MailRule(mine, userLabels: user)
            check("rules: a filter reads back as plain words, the folder implying the skip", r?.folder == "Label_1" && r?.skip == false && r?.star == true && r?.read == true && r?.noSpam == true && r?.att == true
                  && r?.summary(names) == "Emails from news@shop.com and with an attachment \u{2192} Mark as read, star it, move to folder Shopping, never send to Spam")
            let back = r.map { MailRule(filter(String(data: try! JSONSerialization.data(withJSONObject: ($0.json() as [String: Any]).merging(["id": "f1"]) { a, _ in a }), encoding: .utf8)!), userLabels: user) }
            check("rules: what is written to Gmail reads back as the same rule", back != nil && back! == r)
            let block = MailRule(filter(#"{"id":"b1","criteria":{"from":"spam@x.biz"},"action":{"addLabelIds":["Label_2"],"removeLabelIds":["INBOX"]}}"#), userLabels: user)
            check("rules: the filter a block makes reads as Move to folder Blocked", block?.summary(names) == "Emails from spam@x.biz \u{2192} Move to folder Blocked")
            let odd = [#"{"id":"1","criteria":{"from":"a@b.c","size":5000000,"sizeComparison":"larger"},"action":{"removeLabelIds":["INBOX"]}}"#,
                       #"{"id":"2","criteria":{"from":"a@b.c"},"action":{"forward":"x@y.z"}}"#,
                       #"{"id":"3","criteria":{"from":"a@b.c"},"action":{"addLabelIds":["CATEGORY_PROMOTIONS"]}}"#,
                       #"{"id":"4","criteria":{"from":"a@b.c"},"action":{"addLabelIds":["Label_1"]}}"#]
            check("rules: size, forwarding, categories and a folder that keeps the inbox stay read-only", odd.allSatisfy { MailRule(filter($0), userLabels: user) == nil })
            check("rules: no condition or no action is refused", MailRule().problem != nil && MailRule(from: "a@b.c").problem != nil && r?.problem == nil)
            nonisolated(unsafe) var seen: [String] = []
            nonisolated(unsafe) var failCreate = false, create500 = false, create429 = 0, failDelete = false, blockRule = false, del404 = false, dupBlock = false, twin = false, failList = false
            nonisolated(unsafe) var created: [String: Any]?   // the last filter the stub accepted, listed back afterwards
            StubProtocol.handler = { req in
                let u = req.url!.absoluteString
                if u.contains("oauth2") || u.contains("token") && !u.contains("gmail") { return (200, #"{"access_token":"AT","expires_in":3600}"#) }
                seen.append("\(req.httpMethod ?? "") \(req.url!.path) \(String(data: req.httpBody ?? Data(), encoding: .utf8) ?? "")")
                if req.httpMethod == "POST" && failCreate { return (400, "{}") }
                if req.httpMethod == "POST" && create500 { return (500, "{}") }
                if req.httpMethod == "POST" && create429 > 0 { create429 -= 1; return (429, "{}") }
                if req.httpMethod == "DELETE" && failDelete { return (403, "{}") }
                if req.httpMethod == "DELETE" && del404 { return (404, "{}") }
                if u.contains("/messages") && req.httpMethod == "GET" && failList { return (403, "{}") }
                if u.hasSuffix("/labels") { return (200, #"{"labels":[{"id":"Label_1","name":"Shopping","type":"user"},{"id":"Label_2","name":"Blocked","type":"user"}]}"#) }
                if u.hasSuffix("/settings/filters") && req.httpMethod == "GET" {
                    let extra = created.flatMap { try? JSONSerialization.data(withJSONObject: $0) }.flatMap { String(data: $0, encoding: .utf8) }.map { "," + $0 } ?? ""
                    return (200, blockRule ? #"{"filter":[{"id":"b1","criteria":{"from":"spam@x.biz"},"action":{"addLabelIds":["Label_2"],"removeLabelIds":["INBOX"]}}"# + (dupBlock ? #",{"id":"b2","criteria":{"from":"Spam@x.biz"},"action":{"addLabelIds":["Label_2"],"removeLabelIds":["INBOX"]}}"# : "") + #",{"id":"t1","criteria":{"from":"old@spark.example"},"action":{"addLabelIds":["TRASH"]}},{"id":"t2","criteria":{"from":"x@y.example","subject":"s"},"action":{"addLabelIds":["TRASH"]}},{"id":"t3","criteria":{"from":"x@y.example","hasAttachment":true},"action":{"addLabelIds":["TRASH"]}}"# + (twin ? #",{"id":"tw1","criteria":{"from":"twin@x.biz"},"action":{"addLabelIds":["Label_2"],"removeLabelIds":["INBOX"]}},{"id":"tw2","criteria":{"from":"Twin@x.biz"},"action":{"addLabelIds":["TRASH"]}}"# : "") + "]}" : #"{"filter":[{"id":"f1","criteria":{"from":"news@shop.com"},"action":{"removeLabelIds":["INBOX"]}}"# + extra + "]}")
                }
                if u.contains("/messages") && req.httpMethod == "GET" { return (200, #"{"messages":[{"id":"m1"}]}"#) }
                if req.httpMethod == "POST" && u.hasSuffix("/settings/filters") {
                    created = (try? JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any])?.merging(["id": "new1"]) { a, _ in a }
                }
                return (200, #"{"id":"new1"}"#)
            }
            let st: MailStore = await MainActor.run {
                MailStore(auth: SignInModel(), gmail: GmailClient(auth: pauth, session: session), book: SenderBook(url: cbURL.appendingPathExtension("rb")), seen: SeenBook(url: cbURL.appendingPathExtension("rs")), categories: CategoryBook(url: nil), asides: AsideBook(url: nil), organizer: OrganizerBook(url: nil))
            }
            await st.loadRules()
            var edit = await MainActor.run { st.rules.first?.rule }
            edit?.star = true
            let e1 = await st.saveRule(edit!).error
            let order = seen.filter { $0.hasPrefix("POST") || $0.hasPrefix("DELETE") }
            check("rules: Edit makes the new filter first, then deletes the old one", e1 == nil && order.count == 2 && order[0].hasPrefix("POST /gmail/v1/users/me/settings/filters") && order[0].contains("STARRED") && order[1].hasPrefix("DELETE /gmail/v1/users/me/settings/filters/f1"))
            created = nil; await st.loadRules(); seen = []; failCreate = true
            let e2 = await st.saveRule(edit!).error
            check("rules: when the new filter cannot be made the old one is left alone", e2 != nil && !seen.contains { $0.hasPrefix("DELETE") })
            // a lost reply must not make a second filter: creating a filter is not retried
            seen = []; failCreate = false; create500 = true
            let e3 = await st.saveRule(edit!).error
            create500 = false
            check("rules: a filter create that gets a server error is tried once, not repeated", e3 != nil && seen.filter { $0.hasPrefix("POST") }.count == 1)
            // a 429 means Gmail did nothing, so the create is repeated and then succeeds
            created = nil; seen = []; create429 = 1
            let e3b = await st.saveRule(edit!).error
            check("rules: a filter create that gets 429 is repeated once and then goes through", e3b == nil && seen.filter { $0.hasPrefix("POST") }.count == 2)
            created = nil; await st.loadRules()
            // the old copy cannot be removed: the editor gets the new id, so a second Save does not create it again
            seen = []; failDelete = true
            let e4 = await st.saveRule(edit!)
            failDelete = false
            var again = edit!; again.id = e4.newID ?? ""
            seen = []
            let e5 = await st.saveRule(again)
            check("rules: when the old copy stays, the new id comes back and Save again creates nothing", e4.error != nil && e4.newID == "new1" && seen.filter { $0.hasPrefix("POST") }.isEmpty && e5.error == nil)
            // an identical rule gets a plain message and nothing is sent
            seen = []
            var dup = await MainActor.run { st.rules.first { $0.id == "new1" }!.rule! }; dup.id = ""
            let e6 = await st.saveRule(dup)
            check("rules: an identical rule is refused in plain words", e6.error == "You already have this rule." && seen.filter { $0.hasPrefix("POST") }.isEmpty)
            // deleting the rule a block made is Unblock: the filter goes, old emails return to the inbox
            blockRule = true; created = nil; seen = []
            await st.loadRules()
            let brow = await MainActor.run { st.rules.first! }
            await st.deleteRule(brow)
            check("rules: deleting a block's rule behaves like Unblock (filter deleted, old emails moved back)", brow.fromBlock && seen.contains { $0.hasPrefix("DELETE") && $0.contains("/filters/b1") }
                  && seen.contains { $0.contains("batchModify") && $0.contains("\"addLabelIds\":[\"INBOX\"]") && $0.contains("\"removeLabelIds\":[\"Label_2\"]") })
            // Spark's old blocks (send to Trash) are listed too; Unblock removes only the filter
            await st.loadBlocked()
            let bl = await MainActor.run { st.blocked }
            check("blocking: Spark's send-to-Trash filters are listed (a Trash filter with a subject or an attachment condition is not)", bl.contains { $0.id == "t1" && $0.toTrash } && !bl.contains { $0.id == "t2" || $0.id == "t3" } && bl.contains { $0.id == "b1" && !$0.toTrash })
            check("blocking: the Blocked list counts the emails (Gmail answers a one-email count with a rough 201, so it is never used)", bl.first { $0.id == "b1" }?.count == 1)
            let bsDay = Date(timeIntervalSince1970: 1_700_000_000)
            let bsList = [BlockedEntry(id: "1", from: "zed@a.example", count: 1, latest: bsDay), BlockedEntry(id: "2", from: "@hometalk.example", count: 3, latest: bsDay.addingTimeInterval(86400)),
                          BlockedEntry(id: "3", from: "old@spark.example", count: 0, toTrash: true), BlockedEntry(id: "4", from: "Amy@b.example", count: 1, latest: bsDay)]
            let bsNew = BlockedEntry.sorted(bsList, by: .newest).map(\.id), bsAZ = BlockedEntry.sorted(bsList, by: .az).map(\.id)
            check("blocking: Newest first goes by each sender's newest email, ties A to Z, no email last; A to Z skips \"Everyone at\" and ignores capitals", bsNew == ["2", "4", "1", "3"] && bsAZ == ["4", "2", "3", "1"])
            await st.showEmails(from: bl.first { $0.id == "b1" }!)
            let shown = await MainActor.run { (st.mailbox, st.search) }
            check("blocking: clicking a blocked sender opens the search list for all their emails", shown.0 == .search && shown.1 == "from:\"spam@x.biz\" in:anywhere")
            let now = Date()
            await MainActor.run {
                st.book.approve("friend@ok.example"); st.book.approve("a@gone.example"); st.knownCache["stranger@x.example"] = false
                st.blocked = [BlockedEntry(id: "z", from: "@gone.example", count: 1)]
            }
            func logo(_ email: String, _ labels: [String] = ["INBOX"]) async -> Bool { await MainActor.run { st.logoOK(Mail(id: "l", from: Address(name: "A", email: email), subject: "", snippet: "", date: now, labels: labels)) } }
            let blockedID = await MainActor.run { st.blockedLabelID } ?? "?"
            let okFriend = await logo("friend@ok.example"), okStranger = await logo("stranger@x.example"), okGone = await logo("a@gone.example"), okLabel = await logo("friend@ok.example", [blockedID])
            check("pictures: a company logo is asked for only an approved sender, never a new, blocked (even if approved earlier) or Blocked-label sender", okFriend && !okStranger && !okGone && !okLabel && blockedID == "Label_2")
            await st.select(.blocked)   // back to the Blocked list as the checks below expect
            seen = []
            await st.unblock(bl.first { $0.id == "t1" }!)
            check("blocking: unblocking an old Trash block deletes the filter and moves no emails", seen.contains { $0.hasPrefix("DELETE") && $0.contains("/filters/t1") } && !seen.contains { $0.contains("batchModify") })
            // the filter is already gone (404): the old emails still go back, unless another filter blocks the same sender
            await st.loadBlocked()
            let be = await MainActor.run { st.blocked.first! }
            del404 = true; seen = []
            await st.unblock(be)
            check("blocking: a 404 on delete means already gone, and the old emails still go back", seen.contains { $0.contains("batchModify") })
            dupBlock = true; await st.loadBlocked(); seen = []
            await st.unblock(be)
            check("blocking: a 404 while another filter still blocks the sender moves nothing back", !seen.contains { $0.contains("batchModify") })
            dupBlock = false
            // an old Trash block that is already gone (404) is not an error and moves nothing
            await st.loadBlocked(); seen = []
            await st.unblock(bl.first { $0.id == "t1" }!)
            let errT = await MainActor.run { st.error }
            check("blocking: a 404 on an old Trash block's delete is fine and moves nothing", errT == nil && seen.contains { $0.hasPrefix("DELETE") && $0.contains("/filters/t1") } && !seen.contains { $0.contains("batchModify") })
            del404 = false
            // twin: another filter (here a Trash one, other letter case) still blocks the sender: delete only, no move back, no approve
            twin = true; await st.loadBlocked(); seen = []
            await st.unblock(await MainActor.run { st.blocked.first { $0.id == "tw1" }! })
            let twinState = await MainActor.run { (st.book.isApproved("twin@x.biz"), st.status) }
            check("blocking: Unblock while another filter still blocks the sender only deletes, approves no one, and says so", seen.contains { $0.hasPrefix("DELETE") && $0.contains("/filters/tw1") } && !seen.contains { $0.contains("batchModify") } && !twinState.0 && twinState.1.contains("still blocked by another rule"))
            twin = false
            // half-failed Unblock refreshes the lists; a failed delete (nothing changed) makes no extra calls
            failList = true; seen = []
            await st.unblock(be)
            let errHalf = await MainActor.run { st.error } ?? ""
            let di = seen.firstIndex { $0.hasPrefix("DELETE") }
            check("blocking: a half-failed Unblock re-reads the filters and says so in plain words", di != nil && seen[(di! + 1)...].contains { $0.hasPrefix("GET /gmail/v1/users/me/settings/filters") } && errHalf.contains("couldn't be moved back") && !errHalf.contains("label"))
            failList = false; failDelete = true; seen = []
            await st.unblock(be)
            check("blocking: when the delete itself fails nothing is re-read", !seen.contains { $0.hasPrefix("GET /gmail/v1/users/me/settings/filters") })
            failDelete = false; blockRule = false
            StubProtocol.handler = nil
        }
        return ok
    }
}
#endif
