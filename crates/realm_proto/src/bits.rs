//! Bit-level writer and reader. Values are packed LSB-first into bytes; a
//! reader that runs past the end reports [`DecodeError`] instead of panicking,
//! because every byte it reads came from the network.

/// The payload ended early or held an impossible value.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DecodeError(pub &'static str);

impl core::fmt::Display for DecodeError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        write!(f, "malformed packet: {}", self.0)
    }
}

impl std::error::Error for DecodeError {}

#[derive(Default)]
pub struct BitWriter {
    bytes: Vec<u8>,
    bit: u32,
}

impl BitWriter {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Writes the low `count` bits of `value` (`count` <= 32).
    pub fn bits(&mut self, value: u32, count: u32) {
        debug_assert!(count <= 32);
        for i in 0..count {
            if self.bit == 0 {
                self.bytes.push(0);
            }
            if (value >> i) & 1 == 1 {
                let last = self.bytes.len() - 1;
                self.bytes[last] |= 1 << self.bit;
            }
            self.bit = (self.bit + 1) % 8;
        }
    }

    pub fn bool(&mut self, value: bool) {
        self.bits(u32::from(value), 1);
    }

    pub fn u8(&mut self, value: u8) {
        self.bits(u32::from(value), 8);
    }

    pub fn u16(&mut self, value: u16) {
        self.bits(u32::from(value), 16);
    }

    pub fn u32(&mut self, value: u32) {
        self.bits(value, 32);
    }

    /// A signed value in the smallest of four widths (8, 14, 20 or 32 bits)
    /// plus a 2-bit width tag. Small deltas cost 10 bits.
    pub fn signed(&mut self, value: i32) {
        let zig = zigzag(value);
        let (tag, width) = match zig {
            0..=0xFF => (0, 8),
            0x100..=0x3FFF => (1, 14),
            0x4000..=0xF_FFFF => (2, 20),
            _ => (3, 32),
        };
        self.bits(tag, 2);
        self.bits(zig, width);
    }

    /// An unsigned count or id delta, same widths as [`Self::signed`].
    pub fn unsigned(&mut self, value: u32) {
        let (tag, width) = match value {
            0..=0xFF => (0, 8),
            0x100..=0x3FFF => (1, 14),
            0x4000..=0xF_FFFF => (2, 20),
            _ => (3, 32),
        };
        self.bits(tag, 2);
        self.bits(value, width);
    }

    #[must_use]
    pub fn finish(self) -> Vec<u8> {
        self.bytes
    }

    #[must_use]
    pub fn bit_len(&self) -> usize {
        if self.bit == 0 {
            self.bytes.len() * 8
        } else {
            (self.bytes.len() - 1) * 8 + self.bit as usize
        }
    }
}

pub struct BitReader<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> BitReader<'a> {
    #[must_use]
    pub fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, pos: 0 }
    }

    pub fn bits(&mut self, count: u32) -> Result<u32, DecodeError> {
        debug_assert!(count <= 32);
        if self.pos + count as usize > self.bytes.len() * 8 {
            return Err(DecodeError("ran past the end"));
        }
        let mut value = 0_u32;
        for i in 0..count {
            let byte = self.bytes[self.pos / 8];
            if (byte >> (self.pos % 8)) & 1 == 1 {
                value |= 1 << i;
            }
            self.pos += 1;
        }
        Ok(value)
    }

    pub fn bool(&mut self) -> Result<bool, DecodeError> {
        Ok(self.bits(1)? == 1)
    }

    pub fn u8(&mut self) -> Result<u8, DecodeError> {
        Ok(self.bits(8)? as u8)
    }

    pub fn u16(&mut self) -> Result<u16, DecodeError> {
        Ok(self.bits(16)? as u16)
    }

    pub fn u32(&mut self) -> Result<u32, DecodeError> {
        self.bits(32)
    }

    pub fn signed(&mut self) -> Result<i32, DecodeError> {
        let width = [8, 14, 20, 32][self.bits(2)? as usize];
        Ok(unzigzag(self.bits(width)?))
    }

    pub fn unsigned(&mut self) -> Result<u32, DecodeError> {
        let width = [8, 14, 20, 32][self.bits(2)? as usize];
        self.bits(width)
    }

    /// Fails unless only zero padding is left (catches trailing garbage and
    /// layout mismatches).
    pub fn end(&self) -> Result<(), DecodeError> {
        if self.bytes.len() * 8 - self.pos >= 8 {
            return Err(DecodeError("trailing bytes"));
        }
        Ok(())
    }
}

fn zigzag(v: i32) -> u32 {
    ((v << 1) ^ (v >> 31)) as u32
}

fn unzigzag(v: u32) -> i32 {
    ((v >> 1) as i32) ^ -((v & 1) as i32)
}
