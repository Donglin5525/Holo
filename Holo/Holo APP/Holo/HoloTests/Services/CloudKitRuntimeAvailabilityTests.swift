//
//  CloudKitRuntimeAvailabilityTests.swift
//  HoloTests
//
//  Covers the runtime guard that prevents unsigned builds from crashing CloudKit startup.
//

import XCTest
@testable import Holo

final class CloudKitRuntimeAvailabilityTests: XCTestCase {

    func test_debugBuildWithoutEmbeddedProvisionProfileDoesNotDisableCloudKitByDefault() {
        XCTAssertTrue(
            CloudKitRuntimeAvailability.isAvailable(
                embeddedProvisionProfile: nil,
                buildConfiguration: .debug
            )
        )
    }

    func test_debugBuildWithProfileMissingCloudKitDisablesCloudKit() {
        let profile = """
        <plist>
        <dict>
            <key>Entitlements</key>
            <dict>
                <key>application-identifier</key>
                <string>6WZ5TXGPQY.com.tangyuxuan.holo-app</string>
            </dict>
        </dict>
        </plist>
        """

        XCTAssertFalse(
            CloudKitRuntimeAvailability.isAvailable(
                embeddedProvisionProfile: profile,
                buildConfiguration: .debug
            )
        )
    }

    func test_debugBuildWithCloudKitProfileEnablesCloudKit() {
        let profile = """
        <plist>
        <dict>
            <key>com.apple.developer.icloud-services</key>
            <array>
                <string>CloudKit</string>
            </array>
            <key>com.apple.developer.icloud-container-identifiers</key>
            <array>
                <string>iCloud.com.tangyuxuan.Holo</string>
            </array>
        </dict>
        </plist>
        """

        XCTAssertTrue(
            CloudKitRuntimeAvailability.isAvailable(
                embeddedProvisionProfile: profile,
                buildConfiguration: .debug
            )
        )
    }
}
