/*
 The MIT License (MIT)

 Copyright (c) 2015-present Badoo Trading Limited.

 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:

 The above copyright notice and this permission notice shall be included in
 all copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 THE SOFTWARE.
*/

import UIKit

public protocol ChatCollectionViewLayoutDelegate: class {
    func chatCollectionViewLayoutModel() -> ChatCollectionViewLayoutModel
}

public struct ItemLayoutData {
    public let height: CGFloat
    public let bottomMargin: CGFloat
    public let isStickToTop: Bool
}

open class ChatCollectionLayoutAttributes: UICollectionViewLayoutAttributes {
    open var originalFrame = CGRect.zero
    open var bottomMargin = CGFloat.zero
    open var isSticking = false

    open override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone) as! ChatCollectionLayoutAttributes
        copy.originalFrame = self.originalFrame
        copy.bottomMargin = self.bottomMargin
        copy.isSticking = self.isSticking
        return copy
    }

    open override func isEqual(_ object: Any?) -> Bool {
        if let rhs = object as? ChatCollectionLayoutAttributes {
            if originalFrame != rhs.originalFrame || bottomMargin != rhs.bottomMargin || isSticking != rhs.isSticking {
                return false
            }
            return super.isEqual(object)
        } else {
            return false
        }
    }
}

public struct ChatCollectionViewLayoutModel {
    let contentSize: CGSize
    let layoutAttributes: [ChatCollectionLayoutAttributes]
    let layoutAttributesBySectionAndItem: [[ChatCollectionLayoutAttributes]]
    let calculatedForWidth: CGFloat
    let stickyAttributes: [ChatCollectionLayoutAttributes]

    public static func createModel(_ collectionViewWidth: CGFloat, itemsLayoutData: [ItemLayoutData]) -> ChatCollectionViewLayoutModel {
        var layoutAttributes = [ChatCollectionLayoutAttributes]()
        var layoutAttributesBySectionAndItem = [[ChatCollectionLayoutAttributes]]()
        layoutAttributesBySectionAndItem.append([ChatCollectionLayoutAttributes]())
        var stickyAttributes: [ChatCollectionLayoutAttributes] = []

        var verticalOffset: CGFloat = 0
        for (index, layoutData) in itemsLayoutData.enumerated() {
            let indexPath = IndexPath(item: index, section: 0)
            let itemSize = CGSize(width: collectionViewWidth, height: layoutData.height)
            let frame = CGRect(origin: CGPoint(x: 0, y: verticalOffset), size: itemSize)
            let attributes = ChatCollectionLayoutAttributes(forCellWith: indexPath)
            attributes.frame = frame
            attributes.originalFrame = frame
            attributes.bottomMargin = layoutData.bottomMargin
            layoutAttributes.append(attributes)
            layoutAttributesBySectionAndItem[0].append(attributes)
            verticalOffset += itemSize.height
            verticalOffset += layoutData.bottomMargin
            if layoutData.isStickToTop {
                stickyAttributes.append(attributes)
            }
        }

        return ChatCollectionViewLayoutModel(
            contentSize: CGSize(width: collectionViewWidth, height: verticalOffset),
            layoutAttributes: layoutAttributes,
            layoutAttributesBySectionAndItem: layoutAttributesBySectionAndItem,
            calculatedForWidth: collectionViewWidth,
            stickyAttributes: stickyAttributes
        )
    }

    public static func createEmptyModel() -> ChatCollectionViewLayoutModel {
        return ChatCollectionViewLayoutModel(
            contentSize: .zero,
            layoutAttributes: [],
            layoutAttributesBySectionAndItem: [],
            calculatedForWidth: 0,
            stickyAttributes: []
        )
    }
}

open class ChatCollectionViewLayout: UICollectionViewLayout {
    var layoutModel: ChatCollectionViewLayoutModel!
    public weak var delegate: ChatCollectionViewLayoutDelegate?

    open override class var layoutAttributesClass: AnyClass {
        return ChatCollectionLayoutAttributes.self
    }
    
    // Optimization: after reloadData we'll get invalidateLayout, but prepareLayout will be delayed until next run loop.
    // Client may need to force prepareLayout after reloadData, but we don't want to compute layout again in the next run loop.
    private var layoutNeedsUpdate = true
    open override func invalidateLayout() {
        super.invalidateLayout()
        self.layoutNeedsUpdate = true
    }

    open override func prepare() {
        super.prepare()
        guard self.layoutNeedsUpdate || layoutModel.calculatedForWidth != collectionView?.bounds.width else { return }
        guard let delegate = self.delegate else {
            self.layoutModel = ChatCollectionViewLayoutModel.createEmptyModel()
            return
        }
        var oldLayoutModel = self.layoutModel
        self.layoutModel = delegate.chatCollectionViewLayoutModel()
        self.layoutNeedsUpdate = false
        DispatchQueue.global(qos: .default).async { () -> Void in
            // Dealloc of layout with 5000 items take 25 ms on tests on iPhone 4s
            // This moves dealloc out of main thread
            if oldLayoutModel != nil {
                // Use nil check above to remove compiler warning: Variable 'oldLayoutModel' was written to, but never read
                oldLayoutModel = nil
            }
        }
    }

    open override var collectionViewContentSize: CGSize {
        return self.layoutModel?.contentSize ?? .zero
    }

    open override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        var attributesArray = [UICollectionViewLayoutAttributes]()
        
        // Find sticky cell and stick it to top
        var stickyCellAttributes: UICollectionViewLayoutAttributes?
        var currentStickyCellY = CGFloat.greatestFiniteMagnitude
        let offset = collectionView!.contentOffset.y + collectionView!.contentInset.top
        for attributes in self.layoutModel.stickyAttributes.reversed() {
            if attributes.originalFrame.minY < offset {
                attributes.frame.origin.y = min(offset, currentStickyCellY - attributes.frame.height)
                attributes.zIndex = 1000
                attributes.isSticking = true
                stickyCellAttributes = attributes
                break
            }
            currentStickyCellY = attributes.frame.minY
        }
        if let attributes = stickyCellAttributes {
            attributesArray.append(attributes)
        }

        // Find any cell that sits within the query rect.
        guard let firstMatchIndex = self.layoutModel.layoutAttributes.binarySearch(predicate: { attribute in
            if attribute.frame.intersects(rect) {
                return .orderedSame
            }
            if attribute.frame.minY > rect.maxY {
                return .orderedDescending
            }
            return .orderedAscending
        }) else { return attributesArray }
        
        // Starting from the match, loop up and down through the array until all the attributes
        // have been added within the query rect.
        for attributes in self.layoutModel.layoutAttributes[..<firstMatchIndex].reversed() {
            guard attributes.frame.maxY >= rect.minY else { break }
            if attributes != stickyCellAttributes {
                attributes.frame = attributes.originalFrame
                attributes.isSticking = false
                attributesArray.append(attributes)
            }
        }
        
        for attributes in self.layoutModel.layoutAttributes[firstMatchIndex...] {
            guard attributes.frame.minY <= rect.maxY else { break }
            if attributes != stickyCellAttributes {
                attributes.frame = attributes.originalFrame
                attributes.isSticking = false
                attributesArray.append(attributes)
            }
        }
        
        return attributesArray
    }

    open override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        if indexPath.section < self.layoutModel.layoutAttributesBySectionAndItem.count && indexPath.item < self.layoutModel.layoutAttributesBySectionAndItem[indexPath.section].count {
            return self.layoutModel.layoutAttributesBySectionAndItem[indexPath.section][indexPath.item]
        }
        assert(false, "Unexpected indexPath requested:\(indexPath)")
        return nil
    }

    open override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        return self.layoutModel.stickyAttributes.count > 0 || self.layoutModel.calculatedForWidth != newBounds.width
    }
}

private extension Array {
    
    func binarySearch(predicate: (Element) -> ComparisonResult) -> Index? {
        var lowerBound = startIndex
        var upperBound = endIndex
        
        while lowerBound < upperBound {
            let midIndex = lowerBound + (upperBound - lowerBound) / 2
            if predicate(self[midIndex]) == .orderedSame {
                return midIndex
            } else if predicate(self[midIndex]) == .orderedAscending {
                lowerBound = midIndex + 1
            } else {
                upperBound = midIndex
            }
        }
        return nil
    }
}
