public import Buffer
public import Buffer_Protocol
public import Cardinal
public import Index
public import Ordinal_Protocol
public import Storage
public import Tagged

extension Storage.Generational: Buffer.`Protocol` where Allocation: ~Copyable, Element: ~Copyable {}
