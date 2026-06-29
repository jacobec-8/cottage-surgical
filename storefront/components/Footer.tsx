export default function Footer() {
  return (
    <footer className="bg-white border-t border-slate-200 mt-12">
      <div className="max-w-6xl mx-auto px-4 py-8 text-sm text-slate-500 flex flex-col sm:flex-row sm:justify-between gap-4">
        <div>
          <div className="font-medium text-slate-700">Cottage Surgical</div>
          <div>8285 Jericho Tpke, Woodbury, NY 11797</div>
        </div>
        <div className="space-y-1">
          <div>516-367-9030 ext 4</div>
          <div>info@cottagepharmacy.com</div>
        </div>
        <div className="text-slate-400 self-end">© 2026 Cottage Surgical</div>
      </div>
    </footer>
  )
}
