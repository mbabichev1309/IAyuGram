import Foundation
import UIKit
import Display
import ItemListUI
import TelegramPresentationData

// A "label + editable value" row that actually reads as one.
//
// ItemListSingleLineInputItem takes its title as an NSAttributedString, and that
// convenience initialiser defaults to the system font in BLACK when attributes are
// omitted — invisible against a dark theme — while the item's default `spacing` is 0,
// which butts the value straight against the label ("Deletedудалено"). Both are easy to
// re-introduce by copying a call site, so every IAyuGram field goes through here.
//
// Values are right-aligned so they line up in one column no matter how wide the labels
// are, the way iOS Settings does it.
func iAyuTextFieldItem(
    presentationData: ItemListPresentationData,
    title: String,
    value: String,
    placeholder: String,
    sectionId: ItemListSectionId,
    textUpdated: @escaping (String) -> Void
) -> ListViewItem {
    let titleString = NSAttributedString(
        string: title,
        font: Font.regular(presentationData.fontSize.itemListBaseFontSize),
        textColor: presentationData.theme.list.itemPrimaryTextColor
    )
    return ItemListSingleLineInputItem(
        presentationData: presentationData,
        title: titleString,
        text: value,
        placeholder: placeholder,
        type: .regular(capitalization: false, autocorrection: false),
        alignment: .right,
        spacing: 12.0,
        sectionId: sectionId,
        textUpdated: textUpdated,
        action: {}
    )
}
