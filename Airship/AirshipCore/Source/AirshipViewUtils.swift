/* Copyright Airship and Contributors */

import Foundation

import SwiftUI

/// NOTE: For internal use only. :nodoc:
public extension Color {
    static var airshipTappableClear: Color { Color.white.opacity(0.001) }
    static var airshipShadowColor: Color { Color.black.opacity(0.33) }
}

/// NOTE: For internal use only. :nodoc:
public extension View {
    /// Wrapper to prevent linter warnings for deprecated onChange method
    /// - Parameters:
    ///   - value: The value to observe for changes.
    ///   - initial: A Boolean value that determines whether the action should be fired initially.
    ///   - action: The action to perform when the value changes.
    /// NOTE: For internal use only. :nodoc:
    @ViewBuilder
    func airshipOnChangeOf<Value: Equatable>(_ value: Value, initial: Bool = false, _ action: @escaping (Value) -> Void) -> some View {
        if #available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *) {
            self.onChange(of: value, initial: initial, {
                action(value)
            })
        } else {
            self.onChange(of: value, perform: action)
        }
    }
}

public extension UIFont {
    static func validateFamily(_ family:String) -> String? {
        //判断返回的airship后台返回的字体苹果是否支持
        var allfontNamesList = [String]()
        
        let fontFamilieList = UIFont.familyNames
        for(i,_) in fontFamilieList.enumerated(){
            let fontFamily = fontFamilieList[i]
            let fontNames = UIFont.fontNames(forFamilyName: fontFamily)
            
            for (ii,_) in fontNames.enumerated(){
                let fontName = fontNames[ii]
                allfontNamesList.append(fontName)
            }
        }
        
        if allfontNamesList.contains(family){
            return family
        } else {
            if !UIFont.fontNames(forFamilyName: family.lowercased()).isEmpty {
                return family
            }
        }
        
        return nil
    }
}


#if !os(watchOS)
/// NOTE: For internal use only. :nodoc:
public extension UIWindow {
    func airshipAddRootController<T: UIViewController>(
        _ viewController: T?
    ) {
        viewController?.modalPresentationStyle = UIModalPresentationStyle.automatic
        viewController?.view.isUserInteractionEnabled = true

        if let viewController = viewController,
           let rootController = self.rootViewController
        {
            rootController.addChild(viewController)
            viewController.didMove(toParent: rootController)
            rootController.view.addSubview(viewController.view)
        }

        self.isUserInteractionEnabled = true
    }

    static func airshipMakeModalReadyWindow(
        scene: UIWindowScene
    ) -> UIWindow {
        let window: UIWindow = UIWindow(windowScene: scene)
        window.accessibilityViewIsModal = true
        window.alpha = 0
        window.makeKeyAndVisible()
        window.isUserInteractionEnabled = false

        return window
    }

    func airshipAnimateIn() {
        self.makeKeyAndVisible()
        self.isUserInteractionEnabled = true

        UIView.animate(
            withDuration: 0.3,
            animations: {
                self.alpha = 1
            },
            completion: { _ in
            }
        )
    }

    func airshipAnimateOut() {
        UIView.animate(
            withDuration: 0.3,
            animations: {
                self.alpha = 0
            },
            completion: { _ in
                self.isHidden = true
                self.isUserInteractionEnabled = false
                self.removeFromSuperview()
            }
        )
    }
}
#endif
