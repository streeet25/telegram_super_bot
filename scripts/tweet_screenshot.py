#!/usr/bin/env python3
import asyncio
import sys

try:
    from playwright.async_api import async_playwright
except ImportError:
    sys.stderr.write("playwright is not installed. Run: pip install playwright\n")
    sys.exit(1)


async def main(url: str, output_path: str) -> int:
    async with async_playwright() as p:
        browser = await p.chromium.launch(args=["--no-sandbox"])
        page = await browser.new_page(
            viewport={"width": 900, "height": 1800},
            device_scale_factor=2,
        )
        await page.goto(url, wait_until="networkidle")
        try:
            await page.wait_for_selector("article", timeout=8000)
            target = page.locator("article").first
        except Exception:
            target = page.locator("body")

        await target.screenshot(path=output_path)
        await browser.close()
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.stderr.write("Usage: tweet_screenshot.py <url> <output_path>\n")
        sys.exit(2)

    exit_code = asyncio.run(main(sys.argv[1], sys.argv[2]))
    sys.exit(exit_code)
