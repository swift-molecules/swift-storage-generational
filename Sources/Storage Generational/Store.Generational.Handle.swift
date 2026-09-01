public import Store
public import Store_Protocol
public import Storage

extension Store.Generational {

    @frozen
    public struct Handle: Hashable, Sendable {

        public let index: Int

        public let generation: Int
        @usableFromInline
        internal init(index: Int, generation: Int) {
            self.index = index
            self.generation = generation
        }
    }
}
