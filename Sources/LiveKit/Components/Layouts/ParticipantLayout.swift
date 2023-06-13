/*
 * Copyright 2023 LiveKit
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import SwiftUI
import LiveKit

struct ParticipantLayout<Data: RandomAccessCollection, Content: View>: View where Data.Element: Identifiable, Data.Index: Hashable {

    @EnvironmentObject var ui: UIPreference

    private let data: Data
    private let spacing: CGFloat?
    private let viewBuilder: (Data.Element) -> Content

    private func data(at index: Int) -> Data.Element {
        let dataIndex = data.index(data.startIndex, offsetBy: index)
        return data[dataIndex]
    }

    public init(_ data: Data,
                spacing: CGFloat? = nil,
                content: @escaping (Data.Element) -> Content) {

        self.data = data
        self.viewBuilder = content
        self.spacing = spacing
    }

    func buildGrid(for range: ClosedRange<Int>, axis: Axis, geometry: GeometryProxy) -> some View {
        ScrollView([ axis == .vertical ? .vertical : .horizontal ]) {
            HorVGrid(axis: axis, columns: [GridItem(.flexible())], spacing: computedSpacing) {
                ForEach(range, id: \.self) { i in
                    viewBuilder(data(at: i))
                        .aspectRatio(1, contentMode: .fill)
                }
            }
            //            .padding(axis == .horizontal ? [.leading, .trailing] : [.top, .bottom],
            //                     max(0, ((axis == .horizontal ? geometry.size.width : geometry.size.height)
            //                                - ((axis == .horizontal ? geometry.size.height : geometry.size.width) * CGFloat(range.count)) - (computedSpacing * CGFloat(range.count - 1))) / 2))
        }
    }

    //    func computeColumn(with geometry: GeometryProxy) -> (columns: Int, rows: Int) {
    //        let sqr = Double(data.count).squareRoot()
    //        let r: [Int] = [Int(sqr.rounded()), Int(sqr.rounded(.up))]
    //        let c = geometry.isTall ? r : r.reversed()
    //        return (columns: c[0], rows: c[1])
    //    }
    //
    //    var body: some View {
    //        GeometryReader { geometry in
    //
    //            let computeResult = computeColumn(with: geometry)
    //            VStack(spacing: computedSpacing) {
    //                ForEach(0...(computeResult.rows - 1), id: \.self) { y in
    //                    HStack(spacing: computedSpacing) {
    //                        ForEach(0...(computeResult.columns - 1), id: \.self) { x in
    //                            let index = (y * computeResult.columns) + x
    //                            if index < data.count {
    //                                viewBuilder(data(at: index))
    //                            }
    //                        }
    //                    }
    //                }
    //
    //            }
    //        }
    //    }

    //    func createLayout(with geometry: GeometryProxy) -> [GridItem] {
    //        let availableWidth = geometry.size.width
    //        let numberOfColumns = max(Int(availableWidth / 200), 1)
    //        return Array(repeating: .init(.flexible()), count: numberOfColumns)
    //    }

    private var computedSpacing: CGFloat { 10 }

    var body: some View {
        ScrollView(showsIndicators: true) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 180, maximum: 400))],
                spacing: computedSpacing) {
                ForEach(data.indices, id: \.self) { index in
                    viewBuilder(data[index])
                       .frame(minHeight: 180)
                }
            }
        }
        // ContentView()
    }


    struct ContentView: View {
        let numOfItems = 10
        let numOfColumns = 3
        let spacing: CGFloat = 10

        var body: some View {
            GeometryReader { g in
                let columns = Array(repeating: GridItem(.flexible(minimum: 50, maximum: 100)), count: numOfColumns)
                let numOfRows: Int = Int(ceil(Double(numOfItems) / Double(numOfColumns)))
                let height: CGFloat = (g.size.height - (spacing * CGFloat(numOfRows - 1))) / CGFloat(numOfRows)

                LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
                    ForEach(0..<numOfItems, id: \.self) { object in
                        MyView().frame(minHeight: height, maxHeight: .infinity)
                    }
                }
            }
        }}

    struct MyView: View {
        var body: some View {
            Color(red: Double.random(in: 0...1), green: Double.random(in: 0...1), blue: Double.random(in: 0...1))
        }
    }
}
