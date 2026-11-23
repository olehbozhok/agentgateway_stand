"""Demo MCP server with three tools that need different permissions in Cedar."""

import asyncio

from mcp.server.fastmcp import FastMCP

mcp = FastMCP("stand-tools", host="0.0.0.0", port=8000, stateless_http=True)


@mcp.tool()
def echo(text: str) -> str:
    """Return the text unchanged. Any caller with the mcp:echo scope may call it."""
    return text


@mcp.tool()
def get_sum(a: int, b: int) -> int:
    """Add two numbers. Needs the mcp:sum scope."""
    return a + b


@mcp.tool()
def delete_records(table: str) -> str:
    """Pretend to delete a table. Needs the mcp:admin scope."""
    return f"deleted all records in {table} (not really)"


@mcp.tool()
async def wait(ms: int) -> str:
    """Sleep for `ms` milliseconds, standing in for a tool that calls a real API.
    Used by the latency benchmark. Needs the mcp:echo scope."""
    await asyncio.sleep(max(0, min(ms, 30_000)) / 1000)
    return f"waited {ms} ms"


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
