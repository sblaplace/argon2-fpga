`ifndef BLAKE2B_PKG_SVH
`define BLAKE2B_PKG_SVH

// RFC 7693 IV
`define BLAKE2B_IV0 64'h6a09e667f3bcc908
`define BLAKE2B_IV1 64'hbb67ae8584caa73b
`define BLAKE2B_IV2 64'h3c6ef372fe94f82b
`define BLAKE2B_IV3 64'ha54ff53a5f1d36f1
`define BLAKE2B_IV4 64'h510e527fade682d1
`define BLAKE2B_IV5 64'h9b05688c2b3e6c1f
`define BLAKE2B_IV6 64'h1f83d9abfb41bd6b
`define BLAKE2B_IV7 64'h5be0cd19137e2179

`define ROTR64(x, n) { (x)[(n)-1:0], (x)[63:(n)] }

`endif
