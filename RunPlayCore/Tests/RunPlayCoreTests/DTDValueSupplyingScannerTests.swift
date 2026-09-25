import Foundation
import XCTest
@testable import RunPlayCore

/// Scans an internal subset for value-supplying constructs. These unit-test the
/// scanner directly, which is faster and more precise than driving it through a
/// full parse when checking precedence and comment handling.
final class DTDValueSupplyingScannerTests: XCTestCase {

    func testValueFreeSubsetIsClean() {
        let subset = """
        <!ELEMENT Root (A*)>
        <!ELEMENT A EMPTY>
        <!ATTLIST A v CDATA #REQUIRED w CDATA #IMPLIED>
        <!ATTLIST Root x (a|b) #IMPLIED>
        """
        XCTAssertNil(DTDValueSupplyingScanner.findViolation(in: subset))
    }

    func testEachValueSupplyingConstructIsDetected() {
        XCTAssertEqual(
            DTDValueSupplyingScanner.findViolation(in: "<!ATTLIST A v CDATA \"d\">"),
            .quotedAttributeDefault
        )
        XCTAssertEqual(
            DTDValueSupplyingScanner.findViolation(in: "<!ATTLIST A v CDATA 'd'>"),
            .quotedAttributeDefault
        )
        XCTAssertEqual(
            DTDValueSupplyingScanner.findViolation(in: "<!ATTLIST A v CDATA #FIXED \"d\">"),
            .fixedAttributeDefault
        )
        XCTAssertEqual(
            DTDValueSupplyingScanner.findViolation(in: "<!ENTITY e \"boom\">"),
            .entityDeclaration
        )
        XCTAssertEqual(
            DTDValueSupplyingScanner.findViolation(in: "<!ENTITY % p SYSTEM \"x\">"),
            .entityDeclaration
        )
        XCTAssertEqual(
            DTDValueSupplyingScanner.findViolation(in: "<!NOTATION n SYSTEM \"x\">"),
            .notationDeclaration
        )
    }

    func testRealExportDTDShapeIsClean() {
        // The declaration forms present in a real Apple Health `export.xml`,
        // reconstructed with invented names. Measured on that file: 24 ELEMENT,
        // 23 ATTLIST, 0 ENTITY, 0 NOTATION, 0 #FIXED, 0 quoted defaults.
        let subset = """
        <!ELEMENT HealthData (ExportDate*,Me*,Record*,Workout*)>
        <!ATTLIST HealthData locale CDATA #REQUIRED>
        <!ELEMENT Record (MetadataEntry*)>
        <!ATTLIST Record type CDATA #REQUIRED unit CDATA #IMPLIED value CDATA #IMPLIED \
        sourceName CDATA #REQUIRED sourceVersion CDATA #IMPLIED device CDATA #IMPLIED \
        creationDate CDATA #IMPLIED startDate CDATA #REQUIRED endDate CDATA #REQUIRED>
        <!ELEMENT MetadataEntry EMPTY>
        <!ATTLIST MetadataEntry key CDATA #REQUIRED value CDATA #REQUIRED>
        <!ELEMENT Workout (MetadataEntry*,WorkoutStatistics*,WorkoutRoute*)>
        <!ATTLIST Workout workoutActivityType CDATA #REQUIRED duration CDATA #IMPLIED \
        durationUnit CDATA #IMPLIED totalDistance CDATA #IMPLIED sourceName CDATA #REQUIRED \
        startDate CDATA #REQUIRED endDate CDATA #REQUIRED>
        <!ELEMENT WorkoutStatistics EMPTY>
        <!ATTLIST WorkoutStatistics type CDATA #REQUIRED startDate CDATA #REQUIRED \
        endDate CDATA #REQUIRED average CDATA #IMPLIED minimum CDATA #IMPLIED \
        maximum CDATA #IMPLIED sum CDATA #IMPLIED unit CDATA #IMPLIED>
        <!ELEMENT WorkoutRoute (FileReference*)>
        <!ATTLIST WorkoutRoute sourceName CDATA #REQUIRED startDate CDATA #REQUIRED endDate CDATA #REQUIRED>
        <!ELEMENT FileReference EMPTY>
        <!ATTLIST FileReference path CDATA #REQUIRED>
        """
        XCTAssertNil(
            DTDValueSupplyingScanner.findViolation(in: subset),
            "the real export's declaration forms must elide cleanly"
        )
    }

    func testKeywordsInsideCommentsAreIgnored() {
        let subset = """
        <!-- <!ENTITY e "boom"> <!ATTLIST A v CDATA "d"> <!NOTATION n SYSTEM "x"> -->
        <!ELEMENT Root (A*)>
        """
        XCTAssertNil(DTDValueSupplyingScanner.findViolation(in: subset))
    }

    func testKeywordsInsideProcessingInstructionsAreIgnored() {
        let subset = "<?pi <!ENTITY e \"boom\"> ?><!ELEMENT Root (A*)>"
        XCTAssertNil(DTDValueSupplyingScanner.findViolation(in: subset))
    }

    func testFirstViolationWins() {
        let subset = "<!ENTITY e \"a\"><!ATTLIST A v CDATA \"b\">"
        XCTAssertEqual(DTDValueSupplyingScanner.findViolation(in: subset), .entityDeclaration)
    }

    func testQuotedLiteralContainingAngleBracketDoesNotEndDeclaration() {
        // A `>` inside the quoted default must not terminate the declaration
        // early, which would hide a later violation.
        let subset = "<!ATTLIST A v CDATA \"a>b\"><!ATTLIST A w CDATA #IMPLIED>"
        XCTAssertEqual(DTDValueSupplyingScanner.findViolation(in: subset), .quotedAttributeDefault)
    }

    func testViolationInLaterDeclarationIsFound() {
        let subset = """
        <!ELEMENT Root (A*)>
        <!ATTLIST A v CDATA #REQUIRED>
        <!ATTLIST A w CDATA #IMPLIED>
        <!ATTLIST A x CDATA "late">
        """
        XCTAssertEqual(DTDValueSupplyingScanner.findViolation(in: subset), .quotedAttributeDefault)
    }

    func testEmptyAndWhitespaceSubsetsAreClean() {
        XCTAssertNil(DTDValueSupplyingScanner.findViolation(in: ""))
        XCTAssertNil(DTDValueSupplyingScanner.findViolation(in: "\n\t  \r\n"))
    }
}
