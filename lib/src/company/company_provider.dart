import 'package:flutter_riverpod/flutter_riverpod.dart';

class Company {
  final String id;
  final String name;
  final String slug;
  final String companyType;

  const Company({
    required this.id,
    required this.name,
    required this.slug,
    this.companyType = 'standalone',
  });
}

class CompanyNotifier extends StateNotifier<Company?> {
  CompanyNotifier() : super(null);

  void setCompany(Company company) => state = company;
  void clear() => state = null;
}

final currentCompanyProvider =
    StateNotifierProvider<CompanyNotifier, Company?>((ref) {
  return CompanyNotifier();
});

final companiesProvider = StateProvider<List<Company>>((ref) => []);
