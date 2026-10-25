import { expect, it } from "vitest";
import { menuCase } from "./casing";

it("English button and menu labels in Title Case, the small words left; Chinese as it is", () => {
  expect(menuCase("Mark as done")).toBe("Mark as Done");
  expect(menuCase("Copy full text")).toBe("Copy Full Text");
  expect(menuCase("Hand off to agent…")).toBe("Hand Off to Agent…");
  expect(menuCase("Won’t do")).toBe("Won’t Do");
  expect(menuCase("标为完成")).toBe("标为完成");
  expect(menuCase("交给 Agent…")).toBe("交给 Agent…");
});
