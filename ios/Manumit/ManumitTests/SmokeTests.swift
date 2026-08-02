// Copyright (C) 2026 miband contributors
//
// This file is part of miband.
//
// miband is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// miband is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
//
// Proves the ManumitTests target actually builds, links against Manumit.app
// (TEST_HOST), and runs on CI -- before any real logic depends on it.

import XCTest
@testable import Manumit

final class SmokeTests: XCTestCase {
    func testArithmeticSanity() {
        XCTAssertEqual(2 + 2, 4)
    }
}
