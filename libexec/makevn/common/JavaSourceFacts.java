import com.sun.source.tree.AssignmentTree;
import com.sun.source.tree.CompoundAssignmentTree;
import com.sun.source.tree.IdentifierTree;
import com.sun.source.tree.MemberSelectTree;
import com.sun.source.tree.MethodTree;
import com.sun.source.tree.UnaryTree;
import com.sun.source.util.JavacTask;
import com.sun.source.util.TreeScanner;
import com.sun.source.util.Trees;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Base64;
import java.util.Comparator;
import java.util.HexFormat;
import java.util.List;
import java.util.TreeSet;
import javax.tools.Diagnostic;
import javax.tools.DiagnosticCollector;
import javax.tools.JavaFileObject;
import javax.tools.ToolProvider;

/** Parse source structure without compiling or executing repository code. */
public final class JavaSourceFacts {
    public static void main(final String[] args) throws Exception {
        final var compiler = ToolProvider.getSystemJavaCompiler();
        final var diagnostics = new DiagnosticCollector<JavaFileObject>();
        try (final var files = compiler.getStandardFileManager(diagnostics, null, StandardCharsets.UTF_8)) {
            final var paths = Files.readAllLines(Path.of(args[0]), StandardCharsets.UTF_8);
            final var task = (JavacTask) compiler.getTask(null, files, diagnostics, List.of("-proc:none"),
                    null, files.getJavaFileObjectsFromStrings(paths));
            final var units = task.parse();
            final var positions = Trees.instance(task).getSourcePositions();
            for (final var unit : units) {
                final var source = unit.getSourceFile().getCharContent(true).toString();
                final var ranges = new ArrayList<long[]>();
                final var bodies = new ArrayList<String>();
                final var sha256 = MessageDigest.getInstance("SHA-256");
                new TreeScanner<Void, Void>() {
                    @Override
                    public Void visitMethod(final MethodTree tree, final Void unused) {
                        if (tree.getBody() != null) {
                            ranges.add(new long[]{positions.getStartPosition(unit, tree.getBody()),
                                    positions.getEndPosition(unit, tree.getBody())});
                            final var hash = sha256.digest(tree.getBody().toString().getBytes(StandardCharsets.UTF_8));
                            bodies.add(HexFormat.of().formatHex(hash) + ":"
                                    + Boolean.TRUE.equals(new StateWrites().scan(tree.getBody(), null)));
                        } else {
                            bodies.add("-:false");
                        }
                        return null;
                    }
                }.scan(unit, null);
                final var names = new TreeSet<String>();
                new TreeScanner<Void, Void>() {
                    @Override
                    public Void visitIdentifier(final IdentifierTree tree, final Void unused) {
                        names.add(tree.getName().toString());
                        return super.visitIdentifier(tree, unused);
                    }

                    @Override
                    public Void visitMemberSelect(final MemberSelectTree tree, final Void unused) {
                        names.add(tree.getIdentifier().toString());
                        return super.visitMemberSelect(tree, unused);
                    }
                }.scan(unit, null);
                final var shape = new StringBuilder(source);
                ranges.sort(Comparator.comparingLong((long[] range) -> range[0]).reversed());
                for (final var range : ranges) {
                    if (range[0] < 0 || range[1] < range[0]) {
                        throw new IllegalArgumentException("Incomplete Java syntax");
                    }
                    shape.replace((int) range[0], (int) range[1], "{}");
                }
                final var digest = sha256.digest(shape.toString().getBytes(StandardCharsets.UTF_8));
                final var path = Path.of(unit.getSourceFile().toUri()).toString();
                System.out.println(Base64.getEncoder().encodeToString(path.getBytes(StandardCharsets.UTF_8))
                        + "\t" + HexFormat.of().formatHex(digest) + "\t" + String.join(",", names)
                        + "\t" + String.join(",", bodies));
            }
        }
        if (diagnostics.getDiagnostics().stream().anyMatch(item -> item.getKind() == Diagnostic.Kind.ERROR)) {
            throw new IllegalArgumentException("Cannot derive impact from invalid Java syntax");
        }
    }

    private static final class StateWrites extends TreeScanner<Boolean, Void> {
        @Override
        public Boolean reduce(final Boolean left, final Boolean right) {
            return Boolean.TRUE.equals(left) || Boolean.TRUE.equals(right);
        }

        @Override
        public Boolean visitAssignment(final AssignmentTree tree, final Void unused) {
            return true;
        }

        @Override
        public Boolean visitCompoundAssignment(final CompoundAssignmentTree tree, final Void unused) {
            return true;
        }

        @Override
        public Boolean visitUnary(final UnaryTree tree, final Void unused) {
            return switch (tree.getKind()) {
                case PREFIX_INCREMENT, PREFIX_DECREMENT, POSTFIX_INCREMENT, POSTFIX_DECREMENT -> true;
                default -> super.visitUnary(tree, unused);
            };
        }
    }
}
