// One-off generator for the Arabic وراء الكواليس PDF.
// Moved from the repository root during the production-workspace cleanup.
// Paths are resolved relative to THIS file so it works from any cwd —
// the previous absolute paths broke the moment the file moved.
// Run:  node tools/pdf/generate_pdf.js   (needs `npm i puppeteer`)

const puppeteer = require('puppeteer');

(async () => {
  const browser = await puppeteer.launch();
  const page = await browser.newPage();
  await page.goto('file://' + require('path').join(__dirname, 'script.html'), { waitUntil: 'networkidle0' });
  await page.pdf({ 
      path: require('path').join(__dirname, 'وراء_الكواليس.pdf'), 
      format: 'A4', 
      printBackground: true,
      margin: {
          top: '20px',
          bottom: '20px',
          left: '20px',
          right: '20px'
      }
  });
  await browser.close();
})();
