import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { z } from 'zod';
import { search } from './searcher.js';

const server = new McpServer({
  name: 'satori-mcp',
  version: '1.0.0',
});

server.registerTool(
  'lookup_docs',
  {
    description:
      'Search the Satori documentation and source code for information relevant to a query. ' +
      'Returns the most relevant chunks with their labels and source URLs.',
    inputSchema: z.object({
      query: z.string().describe('Natural language query about Satori'),
      top_k: z.number().int().min(1).max(20).default(5).describe('Number of results to return'),
    }),
  },
  async ({ query, top_k }) => {
    const results = await search(query, top_k);
    const text = results
      .map(r => `### ${r.label}\nSource: ${r.url}\n\n${r.content}`)
      .join('\n\n---\n\n');
    return { content: [{ type: 'text', text }] };
  }
);

const transport = new StdioServerTransport();
await server.connect(transport);
