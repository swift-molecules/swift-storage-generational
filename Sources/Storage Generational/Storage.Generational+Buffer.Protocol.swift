public import Buffer_Protocol

extension Storage.Generational: Buffer.`Protocol` where Allocation: ~Copyable, Element: ~Copyable {}
