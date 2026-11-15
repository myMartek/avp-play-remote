// Was die Kerne von der App erwarten, für den Bau am Mac: die Texte in zwei Sprachen (Sources/Model/Support.swift).
import Foundation

enum Language {
    static var german = false
    static var code: String { german ? "de" : "en" }
}

func L(_ english: String, _ german: String) -> String { Language.german ? german : english }
