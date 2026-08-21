public import Buffer_Protocol_Primitives

extension Storage.Generational: Buffer.`Protocol` where Allocation: ~Copyable, Element: ~Copyable {}
