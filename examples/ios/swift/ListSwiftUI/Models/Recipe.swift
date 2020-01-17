////////////////////////////////////////////////////////////////////////////
//
// Copyright 2020 Realm Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
////////////////////////////////////////////////////////////////////////////

import Foundation
import RealmSwift
import SwiftUI

/// A recipe for a food dish.
final class Recipe: Object {
    /// The unique id of the recipe.
    @objc dynamic var id: String = UUID().uuidString
    /// The name of the recipe.
    @objc dynamic var name: String = ""
    /// The ingredients needed to make this recipe.
    let ingredients = RealmSwift.List<Ingredient>()

    /// Convenience initizlier for Recipe.
    /// - parameter name: The name of the recipe.
    /// - parameter ingredients: A list of ingredients associated with this recipe.
    convenience init(name: String, ingredients: Ingredient...) {
        self.init()
        self.name = name
        self.ingredients.append(objectsIn: ingredients)
    }

    override class func primaryKey() -> String? {
        "id"
    }
}

/// The master list of `Recipe`s stored in realm.
final class Recipes: Object {
    /// Singleton list stored in the local realm.
    static let shared: Recipes = ({
        let realm = try! Realm()

        // If `Recipes` has been created before, fetch it.
        if let recipes = realm.object(ofType: Recipes.self, forPrimaryKey: 0) {
            return recipes
        }

        // Otherwise, add a new one and return it.
        let recipes = Recipes()
        try! realm.write { realm.add(recipes) }
        return recipes
    })()

    @objc dynamic var id: Int = 0

    /// All recipes stored in the realm.
    let recipes = RealmSwift.List<Recipe>()

    override class func primaryKey() -> String? {
        "id"
    }
}
