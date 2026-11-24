import Foundation
import XCTest

final class UpdateConfigurationTests: XCTestCase {
    func testSignedUpdateConfigurationIsEmbeddedInTheApp() {
        let info = Bundle.main.infoDictionary

        XCTAssertEqual(
            info?["SUFeedURL"] as? String,
            "https://raw.githubusercontent.com/mg-i-ant-mor/ai-usage-menubar/main/appcast.xml"
        )
        XCTAssertEqual(
            info?["SUPublicEDKey"] as? String,
            "pB6UOvPJUxcWlHmNx++Gwayq1swlji99bbV8cBkeyg0="
        )
        XCTAssertEqual(info?["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(info?["SURequireSignedFeed"] as? Bool, true)
        XCTAssertEqual(info?["SUVerifyUpdateBeforeExtraction"] as? Bool, true)
        XCTAssertEqual(info?["SUScheduledCheckInterval"] as? Int, 86_400)
    }
}
