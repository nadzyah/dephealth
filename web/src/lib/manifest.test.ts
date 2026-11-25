import { describe, expect, it } from "vitest";

import { MAX_BYTES, projectName, tokenFromLink, validateFile } from "./manifest";

function fileOf(name: string, contents: string, size?: number): File {
    const file = new File([contents], name, { type: "text/plain" });
    if (size !== undefined) {
        Object.defineProperty(file, "size", { value: size });
    }
    return file;
}

describe("validateFile", () => {
    it("names the right file when the manifest is chosen instead of the lockfile", () => {
        const rejection = validateFile(new File(["[package]"], "Cargo.toml"));
        expect(rejection?.reason).toBe("wrong-kind");
        expect(rejection?.message).toContain("Cargo.lock");
    });

    it("accepts a Cargo lockfile", () => {
        expect(validateFile(fileOf("Cargo.lock", "version = 4"))).toBeUndefined();
    });

    it("accepts the extensions a lockfile is renamed to", () => {
        for (const name of ["deps.lock", "manifest.toml", "copy.txt"]) {
            expect(validateFile(fileOf(name, "version = 4"))).toBeUndefined();
        }
    });

    it("refuses an empty file before anything is sent", () => {
        expect(validateFile(fileOf("Cargo.lock", ""))?.reason).toBe("empty");
    });

    it("refuses a file larger than the service accepts", () => {
        const problem = validateFile(fileOf("Cargo.lock", "x", MAX_BYTES + 1));
        expect(problem?.reason).toBe("too-large");
        expect(problem?.message).toContain("2 MB");
    });

    it("refuses something that is plainly not a manifest", () => {
        expect(validateFile(fileOf("holiday.png", "x"))?.reason).toBe("wrong-kind");
    });
});

describe("tokenFromLink", () => {
    const token = "9f2c1ab4e6d8705318a0cb4df2e9173c5b6a8de0417fc2938b5e60a7d41c8f23";

    it("takes the token out of a whole link", () => {
        expect(tokenFromLink(`https://example.test/r/${token}`)).toBe(token);
    });

    it("accepts a trailing slash and surrounding space", () => {
        expect(tokenFromLink(`  https://example.test/r/${token}/  `)).toBe(token);
    });

    it("accepts the token on its own", () => {
        expect(tokenFromLink(token)).toBe(token);
    });

    it("accepts the demo link, which the fixtures answer", () => {
        expect(tokenFromLink("/r/demo")).toBe("demo");
    });

    it("refuses anything that cannot be a token", () => {
        for (const value of ["", "   ", "not-a-token", token.slice(0, 63), `${token}ff`, "/r/"]) {
            expect(tokenFromLink(value)).toBeUndefined();
        }
    });
});

describe("the project a lockfile belongs to", () => {
    const lockfile = [
        "version = 4",
        "",
        "[[package]]",
        'name = "aho-corasick"',
        'version = "1.1.5"',
        'source = "registry+https://github.com/rust-lang/crates.io-index"',
        "",
        "[[package]]",
        'name = "my-service"',
        'version = "0.1.0"',
        'dependencies = ["aho-corasick"]',
    ].join("\n");

    it("is the package the file resolves locally rather than from a registry", () => {
        expect(projectName(lockfile)).toBe("my-service");
    });

    it("is absent when every package came from a registry", () => {
        const registryOnly = lockfile.split("[[package]]").slice(0, 2).join("[[package]]");
        expect(projectName(registryOnly)).toBeUndefined();
    });

    it("is absent for a file that holds no packages", () => {
        expect(projectName("version = 4\n")).toBeUndefined();
    });
});
