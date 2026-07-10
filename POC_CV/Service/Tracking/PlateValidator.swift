import Foundation
//
//  PlateValidator.swift
//  POC_CV
//
//  Created by ngoclv2 on 10/7/26.
//
class PlateValidator {
    
    /// Hàm làm sạch và xác thực biển số xe Việt Nam
    /// - Parameter rawText: Chuỗi chữ thô trả về từ mô hình OCR
    /// - Returns: Chuỗi biển số đã chuẩn hóa đẹp đẽ, hoặc `nil` nếu là biển giả/chữ rác
    static func cleanAndValidatePlate(rawText: String) -> String? {
        var cleaned = rawText.uppercased()
        
        cleaned = cleaned.replacingOccurrences(of: " ", with: "")
        cleaned = cleaned.replacingOccurrences(of: ".", with: "")
        cleaned = cleaned.replacingOccurrences(of: "-", with: "")
        cleaned = cleaned.replacingOccurrences(of: "\n", with: "")
        cleaned = cleaned.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        let pattern = "^[0-9]{2}([A-Z]{1,2}|[A-Z][0-9])[0-9]{4,5}$"
        if cleaned.range(of: pattern, options: .regularExpression) != nil {
            return cleaned
        }
        
        return nil
    }
    
    /// Hàm format lại chuỗi để hiển thị lên màn hình cho người dùng dễ đọc
    /// - Parameter cleanedPlate: Chuỗi đã được validate ở trên (e.g., "30A12345")
    static func formatPlateForDisplay(_ cleanedPlate: String) -> String {
        let cleaned = cleanedPlate.uppercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
        guard cleanedPlate.count > 6 else {
            return cleaned
        }
        let chars = Array(cleaned)
        let prefix = String(chars.prefix(3)) // The first 3 chars: e.g., "30A"
        let suffix = String(chars.suffix(cleaned.count - 3)) // The rest: e.g., "12345"
        if cleaned.count == 8 {
            let first3DigitsOfSuffix = String(suffix.prefix(3))
            let last2DigitsOfSuffix = String(suffix.suffix(2))
            return "\(prefix)-\(first3DigitsOfSuffix).\(last2DigitsOfSuffix)"
        }
        if cleaned.count == 7 {
            return "\(prefix)-\(suffix)"
        }
        return cleaned
    }
}

